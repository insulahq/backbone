import Fastify from 'fastify'
import fastifyJwt from '@fastify/jwt'
import fastifyCors from '@fastify/cors'
import fastifyHelmet from '@fastify/helmet'
import fastifyRateLimit from '@fastify/rate-limit'

import { config } from './config.js'
import authRoute from './routes/auth/index.js'
import clientsRoute from './routes/clients/index.js'
import domainsRoute from './routes/domains/index.js'
import adminRoute from './routes/admin/index.js'

export async function buildApp() {
  const app = Fastify({
    logger: {
      level: config.logLevel,
      ...(config.env === 'development'
        ? { transport: { target: 'pino-pretty', options: { colorize: true } } }
        : {}),
    },
  })

  // Security headers
  await app.register(fastifyHelmet, {
    contentSecurityPolicy: false, // API — no HTML served
  })

  // CORS — allow NetBird-internal panel origins only (adjust as needed)
  await app.register(fastifyCors, {
    origin: config.env === 'development' ? true : [/^http:\/\/100\.76\.\d+\.\d+(:\d+)?$/],
    credentials: true,
  })

  // Rate limiting
  await app.register(fastifyRateLimit, {
    max: config.rateLimit.max,
    timeWindow: config.rateLimit.windowMs,
    errorResponseBuilder: (_request, context) => ({
      success: false,
      error: {
        code: 'RATE_LIMITED',
        message: `Too many requests. Retry after ${Math.ceil(context.ttl / 1000)}s`,
      },
    }),
  })

  // JWT
  await app.register(fastifyJwt, {
    secret: config.jwt.secret,
  })

  // Routes
  await app.register(authRoute)
  await app.register(clientsRoute)
  await app.register(domainsRoute)
  await app.register(adminRoute)

  // Global error handler
  app.setErrorHandler((error, _request, reply) => {
    app.log.error(error)
    return reply.code(500).send({
      success: false,
      error: { code: 'INTERNAL_ERROR', message: 'An unexpected error occurred' },
    })
  })

  // Health endpoint (no auth required)
  app.get('/health', async () => ({ ok: true, ts: Date.now() }))

  return app
}
