import { describe, it, expect } from 'vitest'
import { generateId } from '../../src/lib/id.js'
import { paginatedResponse } from '../../src/lib/pagination.js'
import { PdnsClient } from '../../src/services/powerdns/client.js'
import { errorResponse } from '../../src/lib/errors.js'

describe('generateId', () => {
  it('generates id with correct prefix', () => {
    const id = generateId('client')
    expect(id).toMatch(/^client_[0-9a-f]{10}$/)
  })

  it('generates unique ids', () => {
    const ids = new Set(Array.from({ length: 100 }, () => generateId('x')))
    expect(ids.size).toBe(100)
  })
})

describe('paginatedResponse', () => {
  it('calculates has_more correctly', () => {
    const result = paginatedResponse([1, 2, 3], 10, { limit: 3, offset: 0 })
    expect(result.pagination.has_more).toBe(true)
    expect(result.pagination.total).toBe(10)
  })

  it('has_more is false on last page', () => {
    const result = paginatedResponse([1], 5, { limit: 3, offset: 4 })
    expect(result.pagination.has_more).toBe(false)
  })
})

describe('PdnsClient.toZoneId', () => {
  it('adds trailing dot', () => {
    expect(PdnsClient.toZoneId('example.com')).toBe('example.com.')
  })

  it('does not double-add trailing dot', () => {
    expect(PdnsClient.toZoneId('example.com.')).toBe('example.com.')
  })

  it('lowercases', () => {
    expect(PdnsClient.toZoneId('EXAMPLE.COM')).toBe('example.com.')
  })
})

describe('errorResponse', () => {
  it('formats correctly', () => {
    const r = errorResponse('NOT_FOUND', 'thing not found')
    expect(r.success).toBe(false)
    expect(r.error.code).toBe('NOT_FOUND')
  })
})
