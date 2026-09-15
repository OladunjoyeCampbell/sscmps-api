/**
 * Global error handler middleware
 */
export const errorHandler = (err, req, res, next) => {
  console.error('Error:', err);

  const statusCode = err.statusCode || 500;
  const errorMessage = err.message || 'Internal server error';
  
  // Database error handling
  if (err.code === '23505') {
    return res.status(409).json({
      error: 'Duplicate entry',
      code: 'DUPLICATE',
      detail: err.detail
    });
  }

  if (err.code === '23503') {
    return res.status(400).json({
      error: 'Invalid reference',
      code: 'INVALID_REFERENCE',
      detail: err.detail
    });
  }

  if (err.code === 'P0001') {
    return res.status(400).json({
      error: err.message,
      code: 'BUSINESS_RULE_VIOLATION'
    });
  }

  // Default error response
  res.status(statusCode).json({
    error: errorMessage,
    code: err.code || 'INTERNAL_ERROR',
    ...(process.env.NODE_ENV === 'development' && { stack: err.stack })
  });
};

/**
 * Async wrapper for route handlers
 */
export const asyncHandler = (fn) => (req, res, next) => {
  Promise.resolve(fn(req, res, next)).catch(next);
};