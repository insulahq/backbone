import type { FastifyPluginAsync, FastifyRequest, FastifyReply } from 'fastify'
import fp from 'fastify-plugin'

export type Role = 'admin' | 'billing' | 'support' | 'read-only'

export interface JwtPayload {
  sub: string
  role: Role
  iat: number
  exp: number
}

declare module '@fastify/jwt' {
  interface FastifyJWT {
    // payload is what we sign (iat/exp added by library)
    payload: Omit<JwtPayload, 'iat' | 'exp'>
    user: JwtPayload
  }
}

/**
 * Route preHandler that verifies the JWT and attaches user to request.
 * Usage: { preHandler: [fastify.authenticate] }
 */
export async function authenticate(request: FastifyRequest, reply: FastifyReply): Promise<void> {
  try {
    await request.jwtVerify()
  } catch (err) {
    reply.code(401).send({
      success: false,
      error: { code: 'UNAUTHORIZED', message: 'Invalid or missing token' },
    })
  }
}

/**
 * Factory that returns a preHandler checking that the caller has one of the
 * required roles.
 */
export function requireRole(...roles: Role[]) {
  return async (request: FastifyRequest, reply: FastifyReply): Promise<void> => {
    await authenticate(request, reply)
    if (reply.sent) return
    const { role } = request.user
    if (!roles.includes(role)) {
      reply.code(403).send({
        success: false,
        error: {
          code: 'FORBIDDEN',
          message: `Role '${role}' is not allowed. Required: ${roles.join(', ')}`,
        },
      })
    }
  }
}

/** Convenience preHandlers */
export const adminOnly = requireRole('admin')
export const adminOrSupport = requireRole('admin', 'support')
export const anyRole = requireRole('admin', 'billing', 'support', 'read-only')

const authPlugin: FastifyPluginAsync = async (fastify) => {
  // Decorate fastify with the authenticate helper for convenience
  fastify.decorate('authenticate', authenticate)
}

export default fp(authPlugin, { name: 'auth' })
