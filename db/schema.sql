-- =====================================================================
-- BAIGR Outreach System — Supabase / Postgres schema
-- Prefix: bx_   (kept separate from the older tables so nothing breaks)
-- Run this whole file once in Supabase → SQL Editor.
-- Safe to re-run: everything is IF NOT EXISTS / idempotent.
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------
-- 1. bx_config — runtime switches, editable from the Supabase UI
--    Single row, id = 1.
-- ---------------------------------------------------------------------
create table if not exists bx_config (
  id                  int primary key default 1,

  -- Which driver actually delivers WhatsApp messages:
  --   'evolution' = Evolution API / WAHA bridge on your own number  (free-form text, you can also open WhatsApp yourself)
  --   'cloud'     = Meta WhatsApp Cloud API                          (first contact must be an approved template)
  --   'wame'      = no auto-send; Telegram gives you a wa.me link    (100% ban-safe fallback)
  whatsapp_driver     text not null default 'wame',

  -- Master kill switch. false = nothing is ever delivered to a real customer.
  live_sending        boolean not null default false,

  -- Evolution API / WAHA
  evolution_base_url  text,
  evolution_instance  text,

  -- Meta WhatsApp Cloud API
  cloud_phone_number_id text,
  cloud_template_name   text,
  meta_verify_token     text,   -- the token you type into Meta's webhook setup screen

  -- Google Places key used by BX · Lead Engine (change it here, nowhere else)
  google_api_key      text,

  -- Anti-ban pacing for outbound sends
  min_send_gap_seconds  int not null default 45,
  daily_send_cap        int not null default 80,

  -- Telegram chat that owns the bot (filled automatically on /start)
  owner_chat_id       text,

  -- Company profile injected into every AI prompt
  agency_name         text not null default 'BAIGR',
  agency_site         text not null default 'https://baigr.com',
  agency_profile      text,

  updated_at          timestamptz not null default now(),

  constraint bx_config_singleton check (id = 1)
);

-- Seeded so the system runs immediately after this file. Change any of it
-- from Table Editor -> bx_config at any time.
insert into bx_config (
  id, owner_chat_id, google_api_key, agency_profile
) values (
  1,
  '8638221349',
  'AIzaSyAeonJdd0Fc3o82cwE35MAkyk6PkRg_8Zo',
  'BAIGR is a digital agency. It builds websites and landing pages, online stores, '
  'appointment booking systems with a full admin panel (clinics, dentists, barbers, salons), '
  'WhatsApp bots that answer customers automatically, AI-generated photo and video content, '
  'paid social campaign management, and custom business automation systems.'
) on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 2. bx_sessions — Telegram conversation state machine (one per chat)
--    step: IDLE | ASK_COUNTRY | ASK_CITY | ASK_NICHE | ASK_COUNT
--          | RUNNING | ASK_EDIT
-- ---------------------------------------------------------------------
create table if not exists bx_sessions (
  chat_id        text primary key,
  step           text not null default 'IDLE',
  country        text,
  city           text,
  niche          text,
  target_count   int  not null default 50,
  edit_lead_id   text,          -- lead awaiting an edit instruction
  updated_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. bx_runs — one discovery batch
-- ---------------------------------------------------------------------
create table if not exists bx_runs (
  id             uuid primary key default gen_random_uuid(),
  chat_id        text,
  country        text,
  city           text,
  niche          text,
  target_count   int,
  found_count    int  not null default 0,
  new_count      int  not null default 0,
  status         text not null default 'RUNNING',   -- RUNNING | DONE | FAILED
  error          text,
  created_at     timestamptz not null default now(),
  finished_at    timestamptz
);

-- ---------------------------------------------------------------------
-- 4. bx_leads — the core table: one row per discovered business
-- ---------------------------------------------------------------------
create table if not exists bx_leads (
  id              uuid primary key default gen_random_uuid(),
  run_id          text,          -- bx_runs.id, kept as text: n8n writes '' for null
  chat_id         text,

  -- discovery (Google Places)
  place_id        text,
  name            text not null,
  category        text,
  country         text,
  city            text,
  address         text,
  phone_raw       text,
  phone_e164      text,          -- digits only, no '+', used as the WhatsApp id
  website         text,
  maps_url        text,
  rating          numeric not null default 0,
  reviews         int not null default 0,

  -- enrichment
  email           text,
  socials         jsonb not null default '{}'::jsonb,   -- {instagram, facebook, tiktok, linkedin, x}
  site_excerpt    text,
  site_ok         boolean not null default false,

  -- AI intelligence
  language        text,          -- ar | en | tr | ...
  problem         text,          -- the concrete problem we spotted
  evidence        text,          -- why we believe it (from the site / listing)
  service_code    text,          -- see bx_services below
  service_name    text,
  pitch_angle     text,
  fit_score       int  not null default 0,
  priority        int  not null default 0,
  intel_notes     text,

  -- the outbound message awaiting your approval
  message         text,
  message_version int  not null default 1,

  -- lifecycle
  status          text not null default 'DISCOVERED',
  -- DISCOVERED : row created from Google Places
  -- READY       : AI research + message written, waiting in the queue
  -- QUEUED      : the two Telegram cards are posted, waiting for your button
  -- SENT        : you pressed ✅ and WhatsApp delivered it
  -- REPLIED     : the customer answered
  -- DELETED     : you pressed 🗑
  -- NO_PHONE / SKIPPED / FAILED : not contactable
  skip_reason     text,

  tg_intel_msg_id  text,         -- Telegram message id of the intel card
  tg_card_msg_id   text,         -- Telegram message id of the message card

  sent_at         timestamptz,
  replied_at      timestamptz,
  reply_text      text,
  reply_intent    text,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- Dedupe: never contact the same place or the same number twice.
create unique index if not exists bx_leads_place_uidx
  on bx_leads (place_id) where place_id is not null;
create unique index if not exists bx_leads_phone_uidx
  on bx_leads (phone_e164) where phone_e164 is not null;

create index if not exists bx_leads_status_idx   on bx_leads (status);
create index if not exists bx_leads_run_idx      on bx_leads (run_id);
create index if not exists bx_leads_priority_idx on bx_leads (priority desc);

-- ---------------------------------------------------------------------
-- 5. bx_threads — one WhatsApp conversation, and who is driving it
-- ---------------------------------------------------------------------
create table if not exists bx_threads (
  id             uuid primary key default gen_random_uuid(),
  wa_id          text not null unique,          -- customer number, digits only
  lead_id        text,                          -- bx_leads.id; text so an empty n8n value is harmless

  ai_enabled     boolean not null default true, -- false = you took over manually
  takeover_at    timestamptz,                   -- when a human last typed in this chat

  last_in_at     timestamptz,
  last_out_at    timestamptz,
  msg_count      int not null default 0,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 6. bx_messages — full transcript, both directions
-- ---------------------------------------------------------------------
create table if not exists bx_messages (
  id             uuid primary key default gen_random_uuid(),
  thread_id      text,
  lead_id        text,
  wa_id          text not null,

  direction      text not null,          -- IN | OUT
  actor          text not null default 'AI',  -- AI | HUMAN | SYSTEM
  body           text,
  media_type     text,                   -- text | audio | image | document
  transcript     text,                   -- Whisper output for voice notes
  wa_message_id  text,
  created_at     timestamptz not null default now()
);

create index if not exists bx_messages_wa_idx     on bx_messages (wa_id, created_at desc);
create index if not exists bx_messages_thread_idx on bx_messages (thread_id, created_at);

-- ---------------------------------------------------------------------
-- 7. bx_services — the BAIGR catalogue the AI is allowed to pitch.
--    The AI may ONLY return one of these codes.
-- ---------------------------------------------------------------------
create table if not exists bx_services (
  code           text primary key,
  name_ar        text not null,
  name_en        text not null,
  best_for       text not null,
  proof_point    text,
  active         boolean not null default true
);

insert into bx_services (code, name_ar, name_en, best_for, proof_point) values
  ('WEBSITE',   'تصميم موقع إلكتروني',        'Website design',
   'لا يوجد موقع، أو موقع قديم/بطيء/غير ظاهر على الجوال',
   'موقع سريع يظهر بنتائج البحث ويحوّل الزائر لعميل'),
  ('ECOMMERCE', 'متجر إلكتروني',              'E-commerce store',
   'يبيع منتجات عبر إنستغرام/واتساب فقط بدون متجر',
   'متجر بسلة دفع ولوحة تحكم ومخزون'),
  ('BOOKING',   'نظام حجز مواعيد',            'Appointment booking system',
   'عيادات، صالونات حلاقة، مراكز تجميل، أي عمل بالمواعيد',
   'حجز أونلاين + تذكير تلقائي + لوحة تحكم كاملة'),
  ('WHATSAPP',  'بوت واتساب للرد على العملاء','WhatsApp AI reply bot',
   'رسائل كثيرة بدون رد، أو رد متأخر خارج الدوام',
   'رد خلال ثوانٍ 24/7 ويحوّل السؤال لحجز'),
  ('CREATIVE',  'تصميم صور وفيديوهات بالذكاء الاصطناعي', 'AI creative production',
   'محتوى ضعيف أو صور بجودة منخفضة على السوشال',
   'صور وفيديوهات احترافية بتكلفة وزمن أقل'),
  ('ADS',       'إدارة حملات وإعلانات السوشال','Paid social & campaign management',
   'لا توجد إعلانات، أو إعلانات بدون قياس نتائج',
   'حملات مبنية على أرقام وتكلفة عميل واضحة'),
  ('AUTOMATION','بناء نظام أتمتة',            'Business automation system',
   'عمل يدوي متكرر: متابعة عملاء، فواتير، تقارير',
   'أتمتة توفّر ساعات عمل أسبوعياً')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- 8. bx_send_log — pacing / daily cap enforcement
-- ---------------------------------------------------------------------
create table if not exists bx_send_log (
  id          uuid primary key default gen_random_uuid(),
  lead_id     text,
  wa_id       text,
  driver      text,
  ok          boolean not null default true,
  error       text,
  created_at  timestamptz not null default now()
);

create index if not exists bx_send_log_day_idx on bx_send_log (created_at desc);

-- ---------------------------------------------------------------------
-- 9. updated_at triggers
-- ---------------------------------------------------------------------
create or replace function bx_touch_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists bx_leads_touch    on bx_leads;
drop trigger if exists bx_threads_touch  on bx_threads;
drop trigger if exists bx_sessions_touch on bx_sessions;
drop trigger if exists bx_config_touch   on bx_config;

create trigger bx_leads_touch    before update on bx_leads    for each row execute function bx_touch_updated_at();
create trigger bx_threads_touch  before update on bx_threads  for each row execute function bx_touch_updated_at();
create trigger bx_sessions_touch before update on bx_sessions for each row execute function bx_touch_updated_at();
create trigger bx_config_touch   before update on bx_config   for each row execute function bx_touch_updated_at();

-- ---------------------------------------------------------------------
-- 10. bx_report — the "Excel" view: contacted / no reply / replied
-- ---------------------------------------------------------------------
create or replace view bx_report as
select
  l.name                                   as "Business",
  l.category                               as "Category",
  l.city                                   as "City",
  l.country                                as "Country",
  l.phone_raw                              as "Phone",
  l.website                                as "Website",
  l.maps_url                               as "Google Maps",
  l.email                                  as "Email",
  l.service_name                           as "Offered service",
  l.problem                                as "Detected problem",
  l.priority                               as "Priority",
  case
    when l.status = 'REPLIED'                       then 'ردّ'
    when l.status = 'SENT'                          then 'لم يرد بعد'
    when l.status in ('DELETED','SKIPPED')          then 'تم التخطي'
    when l.status = 'NO_PHONE'                      then 'بدون رقم'
    else 'بانتظار الموافقة'
  end                                      as "Status",
  l.reply_intent                           as "Reply intent",
  l.reply_text                             as "Reply",
  to_char(l.sent_at,    'YYYY-MM-DD HH24:MI') as "Sent at",
  to_char(l.replied_at, 'YYYY-MM-DD HH24:MI') as "Replied at",
  l.message                                as "Message sent"
from bx_leads l
order by
  case l.status when 'REPLIED' then 1 when 'SENT' then 2 else 3 end,
  l.priority desc,
  l.created_at desc;

-- ---------------------------------------------------------------------
-- 11. Grants — the n8n Supabase credential uses the service_role key,
--     which bypasses RLS. RLS is enabled anyway so nothing is public.
-- ---------------------------------------------------------------------
alter table bx_config   enable row level security;
alter table bx_sessions enable row level security;
alter table bx_runs     enable row level security;
alter table bx_leads    enable row level security;
alter table bx_threads  enable row level security;
alter table bx_messages enable row level security;
alter table bx_services enable row level security;
alter table bx_send_log enable row level security;
