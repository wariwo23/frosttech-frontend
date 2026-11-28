-- Rollback for 20261128081000_report_acknowledgement_reminders.sql
-- This removes reminder automation and its history. Existing report delivery,
-- archive and acknowledgement records are not changed.
select cron.unschedule(jobid) from cron.job where jobname='frosttech-report-acknowledgement-reminders-daily';
drop table if exists public.ft_report_acknowledgement_reminders;
drop function if exists public.ft_process_report_acknowledgement_reminders();
drop function if exists public.ft_prevent_report_acknowledgement_reminder_mutation();
