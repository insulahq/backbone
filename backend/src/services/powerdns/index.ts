import { config } from '../../config.js'
import { PdnsClient } from './client.js'

export { PdnsClient, PdnsError } from './client.js'
export type { PdnsZone, PdnsRRSet, PdnsCreateZonePayload } from './client.js'

/** Singleton clients — reuse across the process lifetime */
export const pdnsNs1 = new PdnsClient({
  baseUrl: config.pdns.ns1.url,
  apiKey: config.pdns.ns1.apiKey,
})

export const pdnsNs2 = new PdnsClient({
  baseUrl: config.pdns.ns2.url,
  apiKey: config.pdns.ns2.apiKey,
})
