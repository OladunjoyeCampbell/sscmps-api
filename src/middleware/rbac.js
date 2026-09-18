// src/middleware/rbac.js

/**
 * Require specific role(s) for access
 */
export const requireRole = (...allowedRoles) => {
  return (req, res, next) => {
    if (!req.user) {
      return res.status(401).json({ error: 'Authentication required', code: 'UNAUTHORIZED' });
    }

    const userRole = req.user.role;

    if (!allowedRoles.includes(userRole)) {
      return res.status(403).json({
        error: 'Access denied: Insufficient permissions',
        code: 'FORBIDDEN',
        required: allowedRoles,
        userRole,
      });
    }

    next();
  };
};

/**
 * Require any of the specified roles (alias)
 */
export const requireAnyRole = requireRole;

/**
 * Require SystemAdmin role
 */
export const requireSystemAdmin = requireRole('SystemAdmin');

/**
 * Require Treasurer or SystemAdmin
 */
export const requireTreasurer = requireRole('Treasurer', 'SystemAdmin');

/**
 * Require LoanCommittee or SystemAdmin
 */
export const requireLoanCommittee = requireRole('LoanCommittee', 'SystemAdmin');

/**
 * Require Loan Committee Chairman or SystemAdmin
 * Only the Chairman of the Loan Committee may approve or decline loans
 */
export const requireLoanCommitteeChairman = requireRole('LoanCommitteeChairman', 'SystemAdmin');

/**
 * Require Trustee (Chairman, Secretary, or Treasurer)
 */
export const requireTrustee = requireRole('Chairman', 'Secretary', 'Treasurer', 'SystemAdmin');

/**
 * Require Management Committee or SystemAdmin
 * (strict — only the explicitly-tagged ManagementCommittee role)
 */
export const requireManagementCommittee = requireRole('ManagementCommittee', 'SystemAdmin');

/**
 * Require admission / member-administration committee access.
 *
 * Bye-law Section 29 defines the Management Committee as the
 * Chairman, Treasurer, and Secretary (ex officio). Section 10
 * entrusts the disposal of admission applications to the
 * Management Committee. Therefore the three officers plus any
 * additionally-tagged ManagementCommittee members must have
 * access to admission endpoints.
 */
export const requireAdmissionCommittee = requireRole(
  'Chairman',
  'Secretary',
  'Treasurer',
  'ManagementCommittee',
  'SystemAdmin'
);