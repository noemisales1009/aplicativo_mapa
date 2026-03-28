import { createClient, type SupabaseClient } from '@supabase/supabase-js';

export const supabaseUrl = 'https://cjqgogtqzmrfxgdfnnos.supabase.co';
export const supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNqcWdvZ3Rxem1yZnhnZGZubm9zIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI3MTk5ODIsImV4cCI6MjA4ODI5NTk4Mn0.hKf72xRTYdknzdJeSICV7VRZ30t6jLbSwHCUmgzpqqs';

// Create client once, bypass navigator.locks for Vite HMR compatibility
export const supabase: SupabaseClient = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    storageKey: 'mapa-auth',
    lock: async <R>(_name: string, _acquireTimeout: number, fn: () => Promise<R>): Promise<R> => {
      return await fn();
    },
  },
});

// Prevent Vite HMR from creating new instances
if (import.meta.hot) {
  import.meta.hot.accept();
}
