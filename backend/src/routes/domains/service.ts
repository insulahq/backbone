import { db } from '../../db/index.js'
import { generateId } from '../../lib/id.js'
import { Errors } from '../../lib/errors.js'
import { paginatedResponse } from '../../lib/pagination.js'
import { pdnsNs1, PdnsClient, PdnsError } from '../../services/powerdns/index.js'
import { config } from '../../config.js'
import type { CreateDomainInput, ListDomainsQuery } from './schema.js'

interface DomainRow {
  id: string
  client_id: string
  name: string
  tld: string
  registrar: string | null
  status: string
  dns_mode: string
  pdns_zone_id: string | null
  primary_nameserver: string | null
  primary_ns_ip: string | null
  cname_target: string | null
  ssl_status: string
  ssl_expiry: string | null
  ssl_auto_renew: number
  created_at: Date
  updated_at: Date
}

function formatDomain(row: DomainRow) {
  return {
    id: row.id,
    client_id: row.client_id,
    name: row.name,
    tld: row.tld,
    registrar: row.registrar,
    status: row.status,
    dns_mode: row.dns_mode,
    ssl_status: row.ssl_status,
    ssl_expiry: row.ssl_expiry,
    ssl_auto_renew: Boolean(row.ssl_auto_renew),
    created_at: row.created_at,
    dns:
      row.dns_mode === 'primary'
        ? {
            mode: 'primary',
            provider: 'powerdns',
            zone_id: row.pdns_zone_id,
            nameservers: [config.nameservers.primary, config.nameservers.secondary],
          }
        : row.dns_mode === 'cname'
          ? { mode: 'cname', cname_target: row.cname_target }
          : {
              mode: 'secondary',
              provider: 'powerdns',
              zone_id: row.pdns_zone_id,
              primary_nameserver: row.primary_nameserver,
              primary_ns_ip: row.primary_ns_ip,
            },
  }
}

export async function listDomains(clientId: string, query: ListDomainsQuery) {
  // Verify client exists
  const client = await db('clients').where('id', clientId).first()
  if (!client) throw Errors.notFound('Client')

  let base = db('domains').where('client_id', clientId)
  if (query.search) base = base.whereLike('name', `%${query.search}%`)

  const [{ count }] = await base.clone().count('* as count')
  const rows = await base
    .orderBy('created_at', 'desc')
    .limit(query.limit)
    .offset(query.offset)
    .select<DomainRow[]>()

  return paginatedResponse(rows.map(formatDomain), Number(count), query)
}

export async function getDomain(clientId: string, domainId: string) {
  const row = await db('domains')
    .where({ id: domainId, client_id: clientId })
    .first<DomainRow>()
  if (!row) throw Errors.notFound('Domain')
  return { success: true as const, data: formatDomain(row) }
}

export async function createDomain(clientId: string, input: CreateDomainInput) {
  const client = await db('clients').where('id', clientId).first()
  if (!client) throw Errors.notFound('Client')

  const existing = await db('domains').where('name', input.name).first()
  if (existing) throw Errors.duplicateDomain()

  const id = generateId('domain')
  const tld = input.name.split('.').slice(-1)[0] ?? ''
  const now = new Date()

  let pdnsZoneId: string | null = null

  if (input.dns_mode === 'primary') {
    // Create primary zone on ns1 — PowerDNS requires trailing dot in zone name
    const zoneId = PdnsClient.toZoneId(input.name)
    try {
      await pdnsNs1.createZone({
        name: zoneId,
        kind: 'Master',
        nameservers: [
          `${config.nameservers.primary}.`,
          `${config.nameservers.secondary}.`,
        ],
      })
      // Trigger NOTIFY so ns2 picks up the new zone via autosecondary
      await pdnsNs1.notifyZone(zoneId).catch(() => {
        /* non-fatal: ns2 reconciliation cron will catch it */
      })
      pdnsZoneId = zoneId
    } catch (err) {
      if (err instanceof PdnsError) throw Errors.pdnsFailed(err.message)
      throw err
    }
  } else if (input.dns_mode === 'secondary') {
    // Create secondary (slave) zone on ns1 from customer's primary NS
    const zoneId = PdnsClient.toZoneId(input.name)
    try {
      await pdnsNs1.createZone({
        name: zoneId,
        kind: 'Slave',
        masters: [input.primary_ns_ip],
      })
      pdnsZoneId = zoneId
    } catch (err) {
      if (err instanceof PdnsError) throw Errors.pdnsFailed(err.message)
      throw err
    }
  }
  // cname mode: no PowerDNS zone

  await db('domains').insert({
    id,
    client_id: clientId,
    name: input.name,
    tld,
    registrar: 'dns_mode' in input && input.dns_mode === 'primary'
      ? (input as { registrar?: string }).registrar ?? null
      : null,
    status: 'active',
    dns_mode: input.dns_mode,
    pdns_zone_id: pdnsZoneId,
    primary_nameserver: input.dns_mode === 'secondary' ? input.primary_nameserver : null,
    primary_ns_ip: input.dns_mode === 'secondary' ? input.primary_ns_ip : null,
    cname_target: input.dns_mode === 'cname' ? `hosting.${config.nameservers.primary}` : null,
    ssl_status: 'none',
    ssl_expiry: null,
    ssl_auto_renew: true,
    created_at: now,
    updated_at: now,
  })

  return getDomain(clientId, id)
}

export async function deleteDomain(clientId: string, domainId: string, purgeDns = false) {
  const row = await db('domains')
    .where({ id: domainId, client_id: clientId })
    .first<DomainRow>()
  if (!row) throw Errors.notFound('Domain')

  if (purgeDns && row.pdns_zone_id) {
    try {
      await pdnsNs1.deleteZone(row.pdns_zone_id)
      // ns2 reconciliation cron will clean up within 5 min automatically
      // For immediate propagation, also attempt ns2 delete (best-effort)
      const { pdnsNs2 } = await import('../../services/powerdns/index.js')
      await pdnsNs2.deleteZone(row.pdns_zone_id).catch(() => {
        /* non-fatal: cron handles cleanup */
      })
    } catch (err) {
      if (err instanceof PdnsError && err.statusCode !== 404) {
        throw Errors.pdnsFailed(err.message)
      }
    }
  }

  await db('domains').where('id', domainId).delete()

  return {
    success: true as const,
    message: 'Domain deleted',
    data: { id: domainId, deleted_at: new Date() },
  }
}
