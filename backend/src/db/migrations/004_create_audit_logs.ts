import type { Knex } from 'knex'

export async function up(knex: Knex): Promise<void> {
  await knex.schema.createTable('audit_logs', (t) => {
    t.increments('id')
    t.string('actor', 255).notNullable()         // user performing action
    t.string('client_id', 32).nullable()          // affected client (if any)
    t.string('resource_type', 64).notNullable()   // 'client', 'domain', 'database', ...
    t.string('resource_id', 64).nullable()         // affected resource ID
    t.string('action', 64).notNullable()           // 'create', 'update', 'delete', ...
    t.json('diff').nullable()                       // before/after snapshot
    t.string('ip_address', 45).nullable()
    t.timestamp('created_at').notNullable().defaultTo(knex.fn.now())
    t.index(['client_id'])
    t.index(['resource_type', 'resource_id'])
    t.index(['created_at'])
  })
}

export async function down(knex: Knex): Promise<void> {
  await knex.schema.dropTableIfExists('audit_logs')
}
