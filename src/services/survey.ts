import { supabase } from '../lib/supabase';

export interface Question {
  id: number;
  question_text: string;
  subscale: string;
  is_inverted: boolean;
}

export async function fetchQuestions(): Promise<Question[]> {
  const { data, error } = await supabase
    .from('questions')
    .select('id, question_text, subscale, is_inverted')
    .order('id', { ascending: true });

  if (error) throw error;
  if (!data || data.length === 0) throw new Error('Nenhuma pergunta encontrada');

  return data as Question[];
}

// setorId continua sendo o UUID de departments (o QR code nao muda)
export async function submitSurveyResponse(
  setorId: string,
  answers: Record<string | number, number>
) {
  const { error } = await supabase.rpc('insert_survey_response', {
    p_department_id: setorId,
    p_answers:       answers,
  });
  if (error) throw error;
}
