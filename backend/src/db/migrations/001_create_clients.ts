import type { Knex } from 'knex'

export async function up(knex: Knex): Promise<void> {
  await knex.schema.createTable('clients', (t) => {
    t.string('id', 32).primary()
    t.string('name', 100).notNullable()
    t.string('email', 255).notNullable().unique()
    t.enum('plan', ['starter', 'business', 'premium']).notNullable()
    t.enum('status', ['active', 'suspended', 'cancelled']).notNullable().defaultTo('active')
    t.timestamps(true, true)
  })

  await knex.schema.createTable('subscriptions', (t) => {
    t.string('client_id', 32).primary().references('id').inTable('clients').onDelete('CASCADE')
    t.enum('status', ['active', 'expired', 'suspended']).notNullable().defaultTo('active')
    t.date('expiry_date').notNullable()
    t.string('external_billing_id', 128).nullable()
    t.text('notes').nullable()
    t.boolean('renewal_reminder_sent').notNullable().defaultTo(false)
    t.timestamps(true, true)
  })
}

export async function down(knex: Knex): Promise<void> {
  await knex.schema.dropTableIfExists('subscriptions')
  await knex.schema.dropTableIfExists('clients')
}
