import type { Knex } from 'knex'

export async function up(knex: Knex): Promise<void> {
  await knex.schema.createTable('client_databases', (t) => {
    t.string('id', 32).primary()
    t.string('client_id', 32).notNullable().references('id').inTable('clients').onDelete('CASCADE')
    t.enum('type', ['mysql', 'postgresql']).notNullable()
    t.string('version', 16).notNullable()
    t.string('name', 64).notNullable()
    t.decimal('size_gb', 10, 2).notNullable().defaultTo(0)
    t.enum('status', ['provisioning', 'healthy', 'degraded', 'deleted']).notNullable().defaultTo('provisioning')
    // credentials (stored encrypted in production via k8s secrets)
    t.string('db_username', 64).notNullable()
    t.string('db_host', 255).notNullable()
    t.integer('db_port').notNullable()
    t.timestamps(true, true)
    t.index(['client_id'])
    t.unique(['client_id', 'name'])
  })
}

export async function down(knex: Knex): Promise<void> {
  await knex.schema.dropTableIfExists('client_databases')
}
