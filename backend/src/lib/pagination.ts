/**
 * Offset-based pagination helpers.
 * Strategy documented in API_PAGINATION_STRATEGY.md.
 */

export interface PaginationParams {
  limit: number
  offset: number
}

export interface PaginatedResponse<T> {
  success: true
  data: T[]
  pagination: {
    limit: number
    offset: number
    total: number
    has_more: boolean
  }
}

export function parsePagination(query: { limit?: unknown; offset?: unknown }): PaginationParams {
  const limit = Math.min(parseInt(String(query.limit ?? 50), 10) || 50, 500)
  const offset = parseInt(String(query.offset ?? 0), 10) || 0
  return { limit, offset }
}

export function paginatedResponse<T>(
  data: T[],
  total: number,
  params: PaginationParams,
): PaginatedResponse<T> {
  return {
    success: true,
    data,
    pagination: {
      limit: params.limit,
      offset: params.offset,
      total,
      has_more: params.offset + params.limit < total,
    },
  }
}
