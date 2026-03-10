import type { Knex } from 'knex'

const config: { [key: string]: Knex.Config } = {
  development: {
    client: 'mysql2',
    connection: {
      host: process.env['DB_HOST'] ?? '127.0.0.1',
      port: parseInt(process.env['DB_PORT'] ?? '3306', 10),
      database: process.env['DB_NAME'] ?? 'platform',
      user: process.env['DB_USER'] ?? 'platform',
      password: process.env['DB_PASSWORD'] ?? '',
      charset: 'utf8mb4',
    },
    migrations: {
      directory: './migrations',
      extension: 'ts',
    },
    seeds: {
      directory: './seeds',
      extension: 'ts',
    },
  },

  production: {
    client: 'mysql2',
    connection: {
      host: process.env['DB_HOST'],
      port: parseInt(process.env['DB_PORT'] ?? '3306', 10),
      database: process.env['DB_NAME'],
      user: process.env['DB_USER'],
      password: process.env['DB_PASSWORD'],
      charset: 'utf8mb4',
    },
    pool: { min: 2, max: 20 },
    migrations: {
      directory: './migrations',
      extension: 'ts',
    },
  },
}

export default config
