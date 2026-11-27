import { createClient } from '@supabase/supabase-js'

// Publishable keys are designed for browser use. Keep RLS enabled on every exposed table.
const supabaseUrl = import.meta.env.VITE_SUPABASE_URL || 'https://wtrseqwjwmexiyuhfklc.supabase.co'
const supabasePublishableKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || 'sb_publishable_tJ1-ot341GjmoWqKXdBFHg_VPsN8Mqu'

export const backendReady = Boolean(supabaseUrl && supabasePublishableKey)
export const supabase = backendReady
  ? createClient(supabaseUrl, supabasePublishableKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true
      }
    })
  : null
