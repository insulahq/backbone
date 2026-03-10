import { z } from 'zod'

export const CreateClientSchema = z.object({
  name: z.string().min(3).max(100),
  email: z.string().email(),
  plan: z.enum(['starter', 'business', 'premium']),
  subscription: z.object({
    expiry_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Must be YYYY-MM-DD'),
    external_billing_id: z.string().min(1),
    notes: z.string().optional(),
  }),
})

export const UpdateClientSchema = z.object({
  name: z.string().min(3).max(100).optional(),
  status: z.enum(['active', 'suspended', 'cancelled']).optional(),
  subscription: z
    .object({
      expiry_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
      status: z.enum(['active', 'expired', 'suspended']).optional(),
      notes: z.string().optional(),
    })
    .optional(),
})

export const ListClientsQuerySchema = z.object({
  limit: z.coerce.number().min(1).max(500).default(50),
  offset: z.coerce.number().min(0).default(0),
  status: z.enum(['active', 'suspended', 'cancelled']).optional(),
  plan: z.enum(['starter', 'business', 'premium']).optional(),
  search: z.string().max(100).optional(),
})

export type CreateClientInput = z.infer<typeof CreateClientSchema>
export type UpdateClientInput = z.infer<typeof UpdateClientSchema>
export type ListClientsQuery = z.infer<typeof ListClientsQuerySchema>
