-- ============================================================================
--  Migration: add an optional per-student phone number
--  Run this ONCE in the Supabase SQL editor on an existing project.
--  Fresh installs of schema.sql already include this column.
-- ============================================================================

alter table public.cards add column if not exists phone text;

-- phone is optional (nullable) and used only by the teacher app for
-- Viber / WhatsApp reminders. It is NOT exposed to students — the
-- get_student_card() function does not return it.
