import type { FastifyPluginAsync } from 'fastify'
import { adminOnly, adminOrSupport } from '../../middleware/auth.js'
import { AppError, errorResponse } from '../../lib/errors.js'
import {
  CreateClientSchema,
  UpdateClientSchema,
  ListClientsQuerySchema,
} from './schema.js'
import {
  listClients,
  getClient,
  createClient,
  updateClient,
  deleteClient,
} from './service.js'

const clientsRoute: FastifyPluginAsync = async (fastify) => {
  const prefix = '/api/v1/clients'

  // GET /api/v1/clients
  fastify.get(prefix, { preHandler: [adminOrSupport] }, async (request, reply) => {
    const query = ListClientsQuerySchema.safeParse(request.query)
    if (!query.success) {
      return reply.code(400).send(errorResponse('VALIDATION_ERROR', query.error.message))
    }
    return listClients(query.data)
  })

  // POST /api/v1/clients
  fastify.post(prefix, { preHandler: [adminOnly] }, async (request, reply) => {
    const body = CreateClientSchema.safeParse(request.body)
    if (!body.success) {
      return reply.code(400).send(errorResponse('VALIDATION_ERROR', body.error.message))
    }
    try {
      const result = await createClient(body.data)
      return reply.code(201).send(result)
    } catch (err) {
      if (err instanceof AppError) {
        return reply.code(err.statusCode).send(errorResponse(err.code, err.message, err.field))
      }
      throw err
    }
  })

  // GET /api/v1/clients/:id
  fastify.get<{ Params: { id: string } }>(`${prefix}/:id`, { preHandler: [adminOrSupport] }, async (request, reply) => {
    try {
      return await getClient(request.params.id)
    } catch (err) {
      if (err instanceof AppError) {
        return reply.code(err.statusCode).send(errorResponse(err.code, err.message))
      }
      throw err
    }
  })

  // PATCH /api/v1/clients/:id
  fastify.patch<{ Params: { id: string } }>(`${prefix}/:id`, { preHandler: [adminOnly] }, async (request, reply) => {
    const body = UpdateClientSchema.safeParse(request.body)
    if (!body.success) {
      return reply.code(400).send(errorResponse('VALIDATION_ERROR', body.error.message))
    }
    try {
      return await updateClient(request.params.id, body.data)
    } catch (err) {
      if (err instanceof AppError) {
        return reply.code(err.statusCode).send(errorResponse(err.code, err.message, err.field))
      }
      throw err
    }
  })

  // DELETE /api/v1/clients/:id
  fastify.delete<{ Params: { id: string }; Querystring: { force?: string } }>(
    `${prefix}/:id`,
    { preHandler: [adminOnly] },
    async (request, reply) => {
      try {
        const force = request.query.force === 'true'
        return await deleteClient(request.params.id, force)
      } catch (err) {
        if (err instanceof AppError) {
          return reply.code(err.statusCode).send(errorResponse(err.code, err.message))
        }
        throw err
      }
    },
  )
}

export default clientsRoute
