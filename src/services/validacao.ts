import { supabase } from '../lib/supabase';

// ============================================================
// Tipos
// ============================================================

export interface ValidationChecklist {
  id: string;
  empresa_id: string;
  department_id: string;
  avaliador: string;
  participantes: string | null;
  data_avaliacao: string;
  severidade_calculada: number | null;
  created_at: string;
  departments?: { name: string; empresa_id: string };
}

export interface ValidationResponse {
  bloco: number;
  pergunta_num: number;
  resposta: string;
  evidencia: string;
}

export interface ValidationEvidencia {
  tipo_evidencia: string;
  marcado: boolean;
  detalhamento: string;
}

export interface ValidationConsolidation {
  dimensao: string;
  status: 'confirmado' | 'parcial' | 'nao_confirmado';
}

export interface ChecklistFormData {
  empresa_id: string;
  department_id: string;
  avaliador: string;
  participantes: string;
  data_avaliacao: string;
  respostas: ValidationResponse[];
  evidencias: ValidationEvidencia[];
  consolidacao: ValidationConsolidation[];
}

// ============================================================
// Fetch
// ============================================================

export async function fetchChecklists(empresaId?: string | null): Promise<ValidationChecklist[]> {
  let query = supabase
    .from('validation_checklists')
    .select('*, departments(name, empresa_id)')
    .order('data_avaliacao', { ascending: false });
  if (empresaId) query = query.eq('empresa_id', empresaId);
  const { data, error } = await query;
  if (error) throw error;
  return (data || []) as ValidationChecklist[];
}

export async function fetchChecklistById(id: string) {
  const [
    { data: checklist, error: e1 },
    { data: respostas, error: e2 },
    { data: evidencias, error: e3 },
    { data: consolidacao, error: e4 },
  ] = await Promise.all([
    supabase.from('validation_checklists').select('*, departments(name, empresa_id)').eq('id', id).single(),
    supabase.from('validation_responses').select('*').eq('checklist_id', id).order('bloco').order('pergunta_num'),
    supabase.from('validation_evidencias').select('*').eq('checklist_id', id),
    supabase.from('validation_consolidation').select('*').eq('checklist_id', id),
  ]);
  if (e1) throw e1;
  if (e2) throw e2;
  if (e3) throw e3;
  if (e4) throw e4;
  return { checklist, respostas: respostas || [], evidencias: evidencias || [], consolidacao: consolidacao || [] };
}

// ============================================================
// Cálculo de Severidade
// ============================================================

const PESO_EVIDENCIAS: Record<string, number> = {
  horas_extras: 2,
  absenteismo: 3,
  rotatividade: 3,
  queixas_formais: 3,
  afastamentos: 4,
};

export function calcularSeveridade(
  evidencias: ValidationEvidencia[],
  consolidacao: ValidationConsolidation[]
): number {
  // Passo 1: score do Bloco 7
  let score = 5; // base
  for (const ev of evidencias) {
    if (ev.marcado) score += PESO_EVIDENCIAS[ev.tipo_evidencia] || 0;
  }

  // Passo 2: mapear pra nível
  let nivel: number;
  if (score <= 6) nivel = 1;
  else if (score <= 8) nivel = 2;
  else if (score <= 10) nivel = 3;
  else if (score <= 12) nivel = 4;
  else nivel = 5;

  // Passo 3: ajuste pelo Bloco 8
  const confirmados = consolidacao.filter(c => c.status === 'confirmado').length;
  const naoConfirmados = consolidacao.filter(c => c.status === 'nao_confirmado').length;
  if (confirmados >= 4) nivel = Math.min(5, nivel + 1);
  if (naoConfirmados >= 4) nivel = Math.max(1, nivel - 1);

  return nivel;
}

// ============================================================
// Salvar (create)
// ============================================================

export async function saveChecklist(form: ChecklistFormData): Promise<string> {
  const severidade = calcularSeveridade(form.evidencias, form.consolidacao);

  // 1. Inserir cabeçalho
  const { data: checklist, error: e1 } = await supabase
    .from('validation_checklists')
    .insert({
      empresa_id: form.empresa_id,
      department_id: form.department_id,
      avaliador: form.avaliador,
      participantes: form.participantes || null,
      data_avaliacao: form.data_avaliacao,
      severidade_calculada: severidade,
    })
    .select('id')
    .single();
  if (e1) throw e1;

  const checklistId = checklist.id;

  // 2. Inserir respostas
  if (form.respostas.length > 0) {
    const { error: e2 } = await supabase.from('validation_responses').insert(
      form.respostas.map(r => ({ checklist_id: checklistId, ...r }))
    );
    if (e2) throw e2;
  }

  // 3. Inserir evidências
  if (form.evidencias.length > 0) {
    const { error: e3 } = await supabase.from('validation_evidencias').insert(
      form.evidencias.map(ev => ({ checklist_id: checklistId, ...ev }))
    );
    if (e3) throw e3;
  }

  // 4. Inserir consolidação
  if (form.consolidacao.length > 0) {
    const { error: e4 } = await supabase.from('validation_consolidation').insert(
      form.consolidacao.map(c => ({ checklist_id: checklistId, ...c }))
    );
    if (e4) throw e4;
  }

  return checklistId;
}

// ============================================================
// Contexto COPSOQ (scores por dimensão de um setor)
// ============================================================

export async function fetchCopsoqContext(departmentId: string) {
  const { data, error } = await supabase
    .from('vw_media_por_categoria_setor')
    .select('category_name, score_medio, semaforo_cor')
    .eq('department_id', departmentId);
  if (error) throw error;
  return data || [];
}
