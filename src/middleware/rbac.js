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
 */
export const requireManagementCommittee = requireRole('ManagementCommittee', 'SystemAdmin');