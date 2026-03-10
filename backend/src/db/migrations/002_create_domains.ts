import type { Knex } from 'knex'

export async function up(knex: Knex): Promise<void> {
  await knex.schema.createTable('domains', (t) => {
    t.string('id', 32).primary()
    t.string('client_id', 32).notNullable().references('id').inTable('clients').onDelete('CASCADE')
    t.string('name', 255).notNullable()
    t.string('tld', 32).notNullable()
    t.string('registrar', 64).nullable()
    t.enum('status', ['active', 'pending', 'suspended', 'deleted']).notNullable().defaultTo('pending')
    t.enum('dns_mode', ['primary', 'cname', 'secondary']).notNullable().defaultTo('primary')
    // primary/secondary DNS
    t.string('pdns_zone_id', 255).nullable()
    // secondary mode: customer's primary NS
    t.string('primary_nameserver', 255).nullable()
    t.string('primary_ns_ip', 45).nullable()
    // cname mode
    t.string('cname_target', 255).nullable()
    // SSL
    t.enum('ssl_status', ['none', 'pending', 'valid', 'expired', 'failed']).notNullable().defaultTo('none')
    t.date('ssl_expiry').nullable()
    t.boolean('ssl_auto_renew').notNullable().defaultTo(true)
    t.timestamps(true, true)
    t.index(['client_id'])
    t.unique(['name'])
  })
}

export async function down(knex: Knex): Promise<void> {
  await knex.schema.dropTableIfExists('domains')
}
