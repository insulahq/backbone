import { randomBytes } from 'node:crypto'

/**
 * Generate a short random ID with a prefix.
 * e.g. generateId('client') → 'client_a3f9c2b1'
 */
export function generateId(prefix: string): string {
  const suffix = randomBytes(5).toString('hex') // 10 hex chars
  return `${prefix}_${suffix}`
}
