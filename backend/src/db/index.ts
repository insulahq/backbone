import knex from 'knex'
import { config } from '../config.js'

const env = config.env === 'production' ? 'production' : 'development'

export const db = knex({
  client: 'mysql2',
  connection: {
    host: config.db.host,
    port: config.db.port,
    database: config.db.name,
    user: config.db.user,
    password: config.db.password,
    charset: 'utf8mb4',
    ...(env === 'production' ? { ssl: { rejectUnauthorized: false } } : {}),
  },
  pool: env === 'production' ? { min: 2, max: 20 } : { min: 0, max: 10 },
})

export type DB = typeof db
