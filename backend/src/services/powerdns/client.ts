/**
 * Thin HTTP client for the PowerDNS REST API.
 * Reference: https://doc.powerdns.com/authoritative/http-api/zone.html
 */

interface PdnsClientOptions {
  baseUrl: string
  apiKey: string
}

export interface PdnsZone {
  id: string
  name: string
  kind: 'Native' | 'Master' | 'Slave'
  serial: number
  notified_serial: number
  masters: string[]
  dnssec: boolean
  rrsets: PdnsRRSet[]
}

export interface PdnsRRSet {
  name: string
  type: string
  ttl: number
  records: { content: string; disabled: boolean }[]
  comments: { content: string; account: string; modified_at: number }[]
}

export interface PdnsCreateZonePayload {
  name: string
  kind: 'Master' | 'Slave' | 'Native'
  nameservers?: string[]
  masters?: string[]
  rrsets?: Partial<PdnsRRSet>[]
}

export class PdnsClient {
  private readonly baseUrl: string
  private readonly headers: Record<string, string>

  constructor({ baseUrl, apiKey }: PdnsClientOptions) {
    this.baseUrl = baseUrl.replace(/\/$/, '')
    this.headers = {
      'X-API-Key': apiKey,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    }
  }

  private async request<T>(method: string, path: string, body?: unknown): Promise<T> {
    const { fetch } = await import('undici')
    const url = `${this.baseUrl}/api/v1/servers/localhost${path}`
    const response = await fetch(url, {
      method,
      headers: this.headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    })

    if (!response.ok) {
      const text = await response.text()
      throw new PdnsError(response.status, text, method, path)
    }

    // 204 No Content
    if (response.status === 204) return undefined as T

    return response.json() as Promise<T>
  }

  async listZones(): Promise<PdnsZone[]> {
    return this.request<PdnsZone[]>('GET', '/zones')
  }

  async getZone(zoneId: string): Promise<PdnsZone> {
    return this.request<PdnsZone>('GET', `/zones/${encodeURIComponent(zoneId)}`)
  }

  async createZone(payload: PdnsCreateZonePayload): Promise<PdnsZone> {
    return this.request<PdnsZone>('POST', '/zones', payload)
  }

  async deleteZone(zoneId: string): Promise<void> {
    return this.request<void>('DELETE', `/zones/${encodeURIComponent(zoneId)}`)
  }

  async patchRRSets(zoneId: string, rrsets: Partial<PdnsRRSet & { changetype: string }>[]): Promise<void> {
    return this.request<void>('PATCH', `/zones/${encodeURIComponent(zoneId)}`, { rrsets })
  }

  async notifyZone(zoneId: string): Promise<void> {
    return this.request<void>('PUT', `/zones/${encodeURIComponent(zoneId)}/notify`)
  }

  /** Convert a plain domain name to PowerDNS canonical zone ID (trailing dot) */
  static toZoneId(domain: string): string {
    const canonical = domain.endsWith('.') ? domain : `${domain}.`
    return canonical.toLowerCase()
  }
}

export class PdnsError extends Error {
  constructor(
    public readonly statusCode: number,
    public readonly body: string,
    public readonly method: string,
    public readonly path: string,
  ) {
    super(`PowerDNS API ${method} ${path} returned ${statusCode}: ${body}`)
    this.name = 'PdnsError'
  }
}
