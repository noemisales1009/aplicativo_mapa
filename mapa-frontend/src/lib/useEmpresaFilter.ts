import { useAuth } from '../context/AuthContext';

/**
 * Retorna o empresa_id para filtrar queries.
 * Admin (dona do SaaS) retorna null = vê tudo.
 * Gestor retorna seu empresa_id = vê só dados da empresa.
 */
export function useEmpresaFilter() {
  const { user, isAdmin } = useAuth();

  // Admin vê tudo, não filtra
  if (isAdmin) return { empresaId: null, shouldFilter: false };

  return { empresaId: user?.empresa_id || null, shouldFilter: true };
}
