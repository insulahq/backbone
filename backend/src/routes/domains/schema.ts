import { z } from 'zod'

const domainNameRegex = /^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$/

export const CreateDomainSchema = z.discriminatedUnion('dns_mode', [
  z.object({
    name: z.string().regex(domainNameRegex, 'Must be a valid FQDN'),
    dns_mode: z.literal('primary'),
    registrar: z.enum(['namecheap', 'godaddy', 'cloudflare', 'manual']).optional(),
  }),
  z.object({
    name: z.string().regex(domainNameRegex, 'Must be a valid FQDN'),
    dns_mode: z.literal('cname'),
  }),
  z.object({
    name: z.string().regex(domainNameRegex, 'Must be a valid FQDN'),
    dns_mode: z.literal('secondary'),
    primary_nameserver: z.string().regex(domainNameRegex, 'Must be a valid FQDN'),
    primary_ns_ip: z.string().ip({ version: 'v4' }),
  }),
])

export const UpdateDomainSchema = z.object({
  ssl_auto_renew: z.boolean().optional(),
  dns_mode: z.enum(['primary', 'cname', 'secondary']).optional(),
  primary_nameserver: z.string().regex(domainNameRegex).optional(),
  primary_ns_ip: z.string().ip({ version: 'v4' }).optional(),
})

export const ListDomainsQuerySchema = z.object({
  limit: z.coerce.number().min(1).max(500).default(50),
  offset: z.coerce.number().min(0).default(0),
  search: z.string().max(255).optional(),
})

export type CreateDomainInput = z.infer<typeof CreateDomainSchema>
export type UpdateDomainInput = z.infer<typeof UpdateDomainSchema>
export type ListDomainsQuery = z.infer<typeof ListDomainsQuerySchema>
