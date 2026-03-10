import { db } from '../../db/index.js'
import { generateId } from '../../lib/id.js'
import { Errors } from '../../lib/errors.js'
import { paginatedResponse } from '../../lib/pagination.js'
import type { CreateClientInput, UpdateClientInput, ListClientsQuery } from './schema.js'

interface ClientRow {
  id: string
  name: string
  email: string
  plan: string
  status: string
  created_at: Date
  updated_at: Date
}

interface SubscriptionRow {
  client_id: string
  status: string
  expiry_date: string
  external_billing_id: string | null
  notes: string | null
  renewal_reminder_sent: number
  created_at: Date
  updated_at: Date
}

function formatClient(client: ClientRow, sub: SubscriptionRow | undefined) {
  const daysUntilExpiry = sub
    ? Math.ceil((new Date(sub.expiry_date).getTime() - Date.now()) / 86400000)
    : null

  return {
    id: client.id,
    name: client.name,
    email: client.email,
    plan: client.plan,
    status: client.status,
    created_at: client.created_at,
    updated_at: client.updated_at,
    subscription: sub
      ? {
          status: sub.status,
          expiry_date: sub.expiry_date,
          external_billing_id: sub.external_billing_id,
          notes: sub.notes,
          days_until_expiry: daysUntilExpiry,
          renewal_reminder_sent: Boolean(sub.renewal_reminder_sent),
        }
      : null,
  }
}

export async function listClients(query: ListClientsQuery) {
  const { limit, offset, status, plan, search } = query

  let base = db('clients')
  if (status) base = base.where('status', status)
  if (plan) base = base.where('plan', plan)
  if (search) {
    base = base.where((qb) =>
      qb.whereLike('name', `%${search}%`).orWhereLike('email', `%${search}%`),
    )
  }

  const [{ count }] = await base.clone().count('* as count')
  const total = Number(count)

  const clients = await base
    .orderBy('created_at', 'desc')
    .limit(limit)
    .offset(offset)
    .select<ClientRow[]>()

  const ids = clients.map((c) => c.id)
  const subs = ids.length
    ? await db('subscriptions').whereIn('client_id', ids).select<SubscriptionRow[]>()
    : []

  const subMap = Object.fromEntries(subs.map((s) => [s.client_id, s]))

  return paginatedResponse(
    clients.map((c) => formatClient(c, subMap[c.id])),
    total,
    { limit, offset },
  )
}

export async function getClient(id: string) {
  const client = await db('clients').where('id', id).first<ClientRow>()
  if (!client) throw Errors.notFound('Client')

  const sub = await db('subscriptions').where('client_id', id).first<SubscriptionRow>()
  return { success: true as const, data: formatClient(client, sub) }
}

export async function createClient(input: CreateClientInput) {
  const existing = await db('clients').where('email', input.email).first()
  if (existing) throw Errors.duplicateEmail()

  const id = generateId('client')
  const now = new Date()

  await db.transaction(async (trx) => {
    await trx('clients').insert({
      id,
      name: input.name,
      email: input.email,
      plan: input.plan,
      status: 'active',
      created_at: now,
      updated_at: now,
    })
    await trx('subscriptions').insert({
      client_id: id,
      status: 'active',
      expiry_date: input.subscription.expiry_date,
      external_billing_id: input.subscription.external_billing_id,
      notes: input.subscription.notes ?? null,
      renewal_reminder_sent: false,
      created_at: now,
      updated_at: now,
    })
  })

  return getClient(id)
}

export async function updateClient(id: string, input: UpdateClientInput) {
  const existing = await db('clients').where('id', id).first<ClientRow>()
  if (!existing) throw Errors.notFound('Client')

  const now = new Date()

  await db.transaction(async (trx) => {
    const clientPatch: Partial<ClientRow> = {}
    if (input.name !== undefined) clientPatch.name = input.name
    if (input.status !== undefined) clientPatch.status = input.status
    if (Object.keys(clientPatch).length > 0) {
      clientPatch.updated_at = now
      await trx('clients').where('id', id).update(clientPatch)
    }

    if (input.subscription) {
      const subPatch: Record<string, unknown> = {}
      if (input.subscription.expiry_date !== undefined) subPatch['expiry_date'] = input.subscription.expiry_date
      if (input.subscription.status !== undefined) subPatch['status'] = input.subscription.status
      if (input.subscription.notes !== undefined) subPatch['notes'] = input.subscription.notes
      if (Object.keys(subPatch).length > 0) {
        subPatch['updated_at'] = now
        // Reset reminder flag when expiry date is extended
        if (subPatch['expiry_date']) subPatch['renewal_reminder_sent'] = false
        await trx('subscriptions').where('client_id', id).update(subPatch)
      }
    }
  })

  return getClient(id)
}

export async function deleteClient(id: string, force = false) {
  const client = await db('clients').where('id', id).first<ClientRow>()
  if (!client) throw Errors.notFound('Client')
  if (client.status !== 'cancelled' && !force) {
    throw Errors.validation('Client must have status "cancelled" before deletion. Use ?force=true to override.')
  }

  await db('clients').where('id', id).delete()

  return {
    success: true as const,
    message: 'Client deleted',
    data: { id, deleted_at: new Date() },
  }
}
