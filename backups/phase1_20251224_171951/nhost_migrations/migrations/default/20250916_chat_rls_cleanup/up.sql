-- 20250916_chat_rls_cleanup.sql
-- تنظيف السياسات القديمة/العامة والإبقاء على السياسات الجديدة الدقيقة.

-- ───────── public.chat_messages ─────────
drop policy if exists chat_messages_insert on public.chat_messages;
drop policy if exists chat_messages_select on public.chat_messages;
drop policy if exists chat_messages_update on public.chat_messages;
drop policy if exists "read messages where I'm participant" on public.chat_messages;
drop policy if exists "insert messages where I'm participant" on public.chat_messages;
-- ───────── public.chat_conversations ─────────
drop policy if exists chat_conversations_insert on public.chat_conversations;
drop policy if exists chat_conversations_select on public.chat_conversations;
drop policy if exists chat_conversations_update on public.chat_conversations;
drop policy if exists "select convs I'm in" on public.chat_conversations;
-- ───────── public.chat_attachments ─────────
drop policy if exists chat_attachments_insert on public.chat_attachments;
drop policy if exists chat_attachments_select on public.chat_attachments;
-- ───────── storage.objects (bucket: chat-attachments) ─────────
-- نحذف السياسات العامة كي لا تسمح برفع/قراءة خارج شرط المشاركة.
drop policy if exists "read chat bucket"   on storage.objects;
drop policy if exists "upload chat bucket" on storage.objects;
-- ملاحظة: نبقي سياساتنا الجديدة:
--   storage.objects: chat_insert_if_participant, chat_delete_if_participant
--   public.*       : msgs_*, conv_*, atts_*;
