-- Multi-channel notification system (issue #429)
-- Adds per-user channel destinations + quiet hours, per-event-type channel
-- preferences, and a queue used to batch non-critical notifications that
-- arrive during a user's quiet hours.

-- Per-user channel destinations and quiet-hours window.
CREATE TABLE IF NOT EXISTS notification_channel_settings (
  user_id             UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  push_token          TEXT,
  slack_webhook_url   TEXT,
  discord_webhook_url TEXT,
  sms_phone_number    TEXT,
  -- Local hour-of-day (0-23) bounding the quiet window. NULL disables quiet
  -- hours. The window may wrap past midnight (e.g. start=22, end=7).
  quiet_hours_start   SMALLINT CHECK (quiet_hours_start BETWEEN 0 AND 23),
  quiet_hours_end     SMALLINT CHECK (quiet_hours_end BETWEEN 0 AND 23),
  updated_at           TIMESTAMPZ NOT NULL DEFAULT NOW()
);

-- Per-user, per-event-type, per-channel enable/disable override.
-- Absence of a row means "use the channel default" (in-app always on; other
-- channels on when a destination is configured).
CREATE TABLE IF NOT EXISTS notification_preferences (
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL,
  channel    TEXT NOT NULL CHECK (channel IN ('in_app', 'push', 'slack', 'discord', 'sms')),
  enabled    BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (user_id, event_type, channel)
);

-- Non-critical notifications parked during quiet hours, flushed as a digest
-- once the window closes.
-- The queue is partitioned by channel so that high-volume delivery lanes
-- (push/sms) can be flushed and retained independently of low-volume ones.
-- Partitioning key is the channel column.
CREATE TABLE IF NOT EXISTS notification_queue (
  id         UUID NOT NULL DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  channel    TEXT NOT NULL,
  type       TEXT NOT NULL,
  title      TEXT NOT NULL,
  body       TEXT,
  link       TEXT,
  created_at TIMESTAMPZ NOT NULL DEFAULT NOW(),
  flushed_at TIMESTAMPZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id, channel)
) PARTITION BY HASH (channel);

-- Partitions for the channels the system currently delivers to. New channels
-- added later should get their own partition in a migration.
CREATE TABLE IF NOT EXISTS notification_queue_in_app
  PARTITION OF notification_queue FOR VALUES IN ('in_app');
CREATE TABLE IF NOT EXISTS notification_queue_push
  PARTITION OF notification_queue FOR VALUES IN ('push');
CREATE TABLE IF NOT EXISTS notification_queue_slack
  PARTITION OF notification_queue FOR VALUES IN ('slack');
CREATE TABLE IF NOT EXISTS notification_queue_discord
  PARTITION OF notification_queue FOR VALUES IN ('discord');
CREATE TABLE IF NOT EXISTS notification_queue_sms
  PARTITION OF notification_queue FOR VALUES IN ('sms');

-- Default partition catches any channel value that does not match an
-- explicit partition, so inserts from new channels do not fail.
CREATE TABLE IF NOT EXISTS notification_queue_default
  PARTITION OF notification_queue DEFAULT;

-- Pending lookup is per-channel so flushers for different channels do not
-- contend on the same index.
CREATE INDEX IF NOT EXISTS notification_queue_pending_idx
  ON notification_queue (channel, user_id, created_at)
  WHERE flushed_at IS NULL;
