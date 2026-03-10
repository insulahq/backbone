/**
 * Auth routes — Phase 1 uses a simple static admin token approach.
 * In Phase 2 this will be replaced by Dex OIDC.
 *
 * POST /api/v1/auth/token
 *   Body: { username, password }
 *   Returns: { token, expires_in }
 *
 * The admin credentials are set via ADMIN_USERNAME / ADMIN_PASSWORD env vars.
 * This is intentionally simple for the MVP — NOT suitable for multi-user production.
 */
import type { FastifyPluginAsync } from 'fastify'
import { z } from 'zod'
import { config } from '../../config.js'
import { errorResponse } from '../../lib/errors.js'


const LoginSchema = z.object({
  username: z.string().min(1),
  password: z.string().min(1),
})

// Hardcoded single admin account for Phase 1 MVP
// Override via ADMIN_USERNAME + ADMIN_PASSWORD env vars
const ADMIN_USERNAME = process.env['ADMIN_USERNAME'] ?? 'admin'
const ADMIN_PASSWORD = process.env['ADMIN_PASSWORD'] ?? ''

const authRoute: FastifyPluginAsync = async (fastify) => {
  fastify.post('/api/v1/auth/token', async (request, reply) => {
    const body = LoginSchema.safeParse(request.body)
    if (!body.success) {
      return reply.code(400).send(errorResponse('VALIDATION_ERROR', body.error.message))
    }

    const { username, password } = body.data

    if (!ADMIN_PASSWORD) {
      return reply
        .code(503)
        .send(errorResponse('AUTH_NOT_CONFIGURED', 'ADMIN_PASSWORD env var is not set'))
    }

    if (username !== ADMIN_USERNAME || password !== ADMIN_PASSWORD) {
      return reply.code(401).send(errorResponse('INVALID_CREDENTIALS', 'Invalid username or password'))
    }

    const payload: Omit<import('../../middleware/auth.js').JwtPayload, 'iat' | 'exp'> = { sub: username, role: 'admin' }
    const token = fastify.jwt.sign(payload, { expiresIn: config.jwt.expiresIn })

    return reply.send({
      success: true,
      data: {
        token,
        token_type: 'Bearer',
        expires_in: config.jwt.expiresIn,
      },
    })
  })
}

export default authRoute
