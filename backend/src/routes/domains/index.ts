import type { FastifyPluginAsync } from 'fastify'
import { adminOrSupport } from '../../middleware/auth.js'
import { AppError, errorResponse } from '../../lib/errors.js'
import { CreateDomainSchema, ListDomainsQuerySchema } from './schema.js'
import { listDomains, getDomain, createDomain, deleteDomain } from './service.js'

const domainsRoute: FastifyPluginAsync = async (fastify) => {
  const prefix = '/api/v1/clients/:clientId/domains'

  // GET /api/v1/clients/:clientId/domains
  fastify.get<{ Params: { clientId: string } }>(prefix, { preHandler: [adminOrSupport] }, async (request, reply) => {
    const query = ListDomainsQuerySchema.safeParse(request.query)
    if (!query.success) {
      return reply.code(400).send(errorResponse('VALIDATION_ERROR', query.error.message))
    }
    try {
      return await listDomains(request.params.clientId, query.data)
    } catch (err) {
      if (err instanceof AppError) return reply.code(err.statusCode).send(errorResponse(err.code, err.message))
      throw err
    }
  })

  // POST /api/v1/clients/:clientId/domains
  fastify.post<{ Params: { clientId: string } }>(prefix, { preHandler: [adminOrSupport] }, async (request, reply) => {
    const body = CreateDomainSchema.safeParse(request.body)
    if (!body.success) {
      return reply.code(400).send(errorResponse('VALIDATION_ERROR', body.error.message))
    }
    try {
      const result = await createDomain(request.params.clientId, body.data)
      return reply.code(201).send(result)
    } catch (err) {
      if (err instanceof AppError) return reply.code(err.statusCode).send(errorResponse(err.code, err.message, err.field))
      throw err
    }
  })

  // GET /api/v1/clients/:clientId/domains/:domainId
  fastify.get<{ Params: { clientId: string; domainId: string } }>(
    `${prefix}/:domainId`,
    { preHandler: [adminOrSupport] },
    async (request, reply) => {
      try {
        return await getDomain(request.params.clientId, request.params.domainId)
      } catch (err) {
        if (err instanceof AppError) return reply.code(err.statusCode).send(errorResponse(err.code, err.message))
        throw err
      }
    },
  )

  // DELETE /api/v1/clients/:clientId/domains/:domainId
  fastify.delete<{ Params: { clientId: string; domainId: string }; Querystring: { purge_dns?: string } }>(
    `${prefix}/:domainId`,
    { preHandler: [adminOrSupport] },
    async (request, reply) => {
      try {
        const purgeDns = request.query.purge_dns === 'true'
        return await deleteDomain(request.params.clientId, request.params.domainId, purgeDns)
      } catch (err) {
        if (err instanceof AppError) return reply.code(err.statusCode).send(errorResponse(err.code, err.message))
        throw err
      }
    },
  )
}

export default domainsRoute
