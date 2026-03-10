/**
 * Application configuration loaded from environment variables.
 * All required vars will throw at startup if missing.
 */

function required(key: string): string {
  const value = process.env[key]
  if (!value) throw new Error(`Missing required env var: ${key}`)
  return value
}

function optional(key: string, fallback: string): string {
  return process.env[key] ?? fallback
}

export const config = {
  env: optional('NODE_ENV', 'development'),
  port: parseInt(optional('PORT', '3000'), 10),
  host: optional('HOST', '127.0.0.1'),
  logLevel: optional('LOG_LEVEL', 'info'),

  jwt: {
    secret: required('JWT_SECRET'),
    expiresIn: optional('JWT_EXPIRES_IN', '1h'),
  },

  db: {
    host: optional('DB_HOST', '127.0.0.1'),
    port: parseInt(optional('DB_PORT', '3306'), 10),
    name: optional('DB_NAME', 'platform'),
    user: optional('DB_USER', 'platform'),
    password: required('DB_PASSWORD'),
  },

  pdns: {
    ns1: {
      url: optional('PDNS_NS1_URL', 'http://100.76.182.198:8081'),
      apiKey: required('PDNS_NS1_API_KEY'),
    },
    ns2: {
      url: optional('PDNS_NS2_URL', 'http://100.76.92.172:8081'),
      apiKey: required('PDNS_NS2_API_KEY'),
    },
  },

  nameservers: {
    primary: optional('NAMESERVER_PRIMARY', 'ns1.phoenix-host.net'),
    secondary: optional('NAMESERVER_SECONDARY', 'ns2.phoenix-host.net'),
  },

  rateLimit: {
    max: parseInt(optional('RATE_LIMIT_MAX', '100'), 10),
    windowMs: parseInt(optional('RATE_LIMIT_WINDOW_MS', '60000'), 10),
  },
} as const
