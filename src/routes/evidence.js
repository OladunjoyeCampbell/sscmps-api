// src/routes/evidence.js
import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { getMemberId, getMemberRole } from '../middleware/auth.js';

const router = express.Router();

/**
 * GET /api/evidence/:notificationId
 * Get a signed URL for payment evidence
 */
router.get('/:notificationId', asyncHandler(async (req, res) => {
  const { notificationId } = req.params;
  const memberId = getMemberId(req);
  const role = getMemberRole(req);

  // Fetch notification
  const { data: notification, error } = await supabaseAdmin
    .from('payment_notifications')
    .select('id, member_id, evidence_url')
    .eq('id', notificationId)
    .single();

  if (error || !notification) {
    return res.status(404).json({ error: 'Payment notification not found' });
  }

  // Authorization: owner OR management
  const isOwner = notification.member_id === memberId;
  const isManagement = ['Treasurer', 'Chairman', 'Secretary', 'ManagementCommittee', 'SystemAdmin'].includes(role);

  if (!isOwner && !isManagement) {
    return res.status(403).json({ error: 'Access denied' });
  }

  if (!notification.evidence_url) {
    return res.status(404).json({ error: 'No evidence attached' });
  }

  // If it's a full URL (old data), return as-is
  if (notification.evidence_url.startsWith('http')) {
    return res.json({ success: true, signed_url: notification.evidence_url });
  }

  // Generate signed URL (valid for 1 hour)
  const { data: signedData, error: signedError } = await supabaseAdmin.storage
    .from('evidence')
    .createSignedUrl(notification.evidence_url, 3600);

  if (signedError) {
    console.error('Signed URL error:', signedError);
    return res.status(500).json({ error: 'Failed to generate signed URL' });
  }

  res.json({
    success: true,
    signed_url: signedData.signedUrl,
    expires_in: 3600,
  });
}));

export default router;