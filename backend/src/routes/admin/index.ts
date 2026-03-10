import type { FastifyPluginAsync } from 'fastify'
import { adminOnly } from '../../middleware/auth.js'
import { db } from '../../db/index.js'
import { pdnsNs1, pdnsNs2 } from '../../services/powerdns/index.js'

const adminRoute: FastifyPluginAsync = async (fastify) => {
  // GET /api/v1/admin/status — health check with dependency status
  fastify.get('/api/v1/admin/status', { preHandler: [adminOnly] }, async (_request, reply) => {
    const checks: Record<string, { ok: boolean; detail?: string }> = {}

    // DB ping
    try {
      await db.raw('SELECT 1')
      checks['database'] = { ok: true }
    } catch (err) {
      checks['database'] = { ok: false, detail: String(err) }
    }

    // PowerDNS ns1 ping
    try {
      await pdnsNs1.listZones()
      checks['pdns_ns1'] = { ok: true }
    } catch (err) {
      checks['pdns_ns1'] = { ok: false, detail: String(err) }
    }

    // PowerDNS ns2 ping
    try {
      await pdnsNs2.listZones()
      checks['pdns_ns2'] = { ok: true }
    } catch (err) {
      checks['pdns_ns2'] = { ok: false, detail: String(err) }
    }

    const allOk = Object.values(checks).every((c) => c.ok)
    return reply.code(allOk ? 200 : 503).send({
      success: allOk,
      status: allOk ? 'healthy' : 'degraded',
      checks,
      timestamp: new Date().toISOString(),
    })
  })
}

export default adminRoute
