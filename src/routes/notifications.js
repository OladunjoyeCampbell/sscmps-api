// src/routes/notifications.js
import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { getMemberId } from '../middleware/auth.js';

const router = express.Router();

/**
 * GET /api/notifications/my
 * List the current member's notifications, newest first.
 * Returns notifications plus the total unread count.
 */
router.get(
  '/my',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);
    const limit = Math.min(parseInt(req.query.limit, 10) || 20, 100);

    const { data: notifications, error } = await supabaseAdmin
      .from('notification_queue')
      .select('id, category, subject, body, payload, read_at, created_at, status')
      .eq('recipient_member_id', memberId)
      .order('created_at', { ascending: false })
      .limit(limit);

    if (error) return res.status(400).json({ error: error.message });

    const { count: unreadCount } = await supabaseAdmin
      .from('notification_queue')
      .select('*', { count: 'exact', head: true })
      .eq('recipient_member_id', memberId)
      .is('read_at', null);

    res.json({
      success: true,
      notifications: notifications || [],
      unread_count: unreadCount || 0,
    });
  })
);

/**
 * GET /api/notifications/unread-count
 * Lightweight endpoint for polling. Returns only the count.
 */
router.get(
  '/unread-count',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);

    const { count, error } = await supabaseAdmin
      .from('notification_queue')
      .select('*', { count: 'exact', head: true })
      .eq('recipient_member_id', memberId)
      .is('read_at', null);

    if (error) return res.status(400).json({ error: error.message });

    res.json({ success: true, unread_count: count || 0 });
  })
);

/**
 * POST /api/notifications/:id/read
 * Mark a single notification as read (only if it belongs to the caller).
 */
router.post(
  '/:id/read',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);
    const { id } = req.params;

    const { error } = await supabaseAdmin
      .from('notification_queue')
      .update({ read_at: new Date().toISOString() })
      .eq('id', id)
      .eq('recipient_member_id', memberId)
      .is('read_at', null);

    if (error) return res.status(400).json({ error: error.message });

    res.json({ success: true });
  })
);

/**
 * POST /api/notifications/read-all
 * Mark every unread notification for the caller as read.
 */
router.post(
  '/read-all',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);

    const { error } = await supabaseAdmin
      .from('notification_queue')
      .update({ read_at: new Date().toISOString() })
      .eq('recipient_member_id', memberId)
      .is('read_at', null);

    if (error) return res.status(400).json({ error: error.message });

    res.json({ success: true });
  })
);

export default router;