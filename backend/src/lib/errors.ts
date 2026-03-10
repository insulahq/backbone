/**
 * Standard API error codes and helper to format error responses.
 * Matches the error format defined in API_ERROR_HANDLING.md.
 */

export interface ApiError {
  code: string
  message: string
  field?: string
}

export interface ErrorResponse {
  success: false
  error: ApiError
}

export function errorResponse(code: string, message: string, field?: string): ErrorResponse {
  return {
    success: false,
    error: { code, message, ...(field ? { field } : {}) },
  }
}

/** Typed application errors that map to HTTP status codes */
export class AppError extends Error {
  constructor(
    public readonly statusCode: number,
    public readonly code: string,
    message: string,
    public readonly field?: string,
  ) {
    super(message)
    this.name = 'AppError'
  }
}

export const Errors = {
  notFound: (resource: string) =>
    new AppError(404, 'NOT_FOUND', `${resource} not found`),

  duplicateEmail: () =>
    new AppError(409, 'DUPLICATE_EMAIL', 'Email already registered', 'email'),

  duplicateDomain: () =>
    new AppError(409, 'DUPLICATE_DOMAIN', 'Domain already registered', 'name'),

  validation: (message: string, field?: string) =>
    new AppError(400, 'VALIDATION_ERROR', message, field),

  quotaExceeded: (resource: string) =>
    new AppError(429, 'QUOTA_EXCEEDED', `${resource} quota exceeded`),

  forbidden: () =>
    new AppError(403, 'FORBIDDEN', 'Insufficient permissions'),

  pdnsFailed: (detail: string) =>
    new AppError(502, 'DNS_PROVISIONING_FAILED', `PowerDNS error: ${detail}`),
}
