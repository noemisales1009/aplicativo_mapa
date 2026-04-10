# COPSOQ II — Redesenho da Base de Dados (Conectando Coleta → Análise)

**Data:** 2026-04-10
**Autor:** Noemi / M.A.P.A.
**Status:** Draft para revisão

---

## 1. Contexto e Problema

O M.A.P.A. hoje tem **duas arquiteturas paralelas e desconectadas** no banco:

### Arquitetura A — Coleta (a que o front-end usa)
- `respostas_brutas` (JSONB) — `submitSurveyResponse` grava aqui uma linha com `{setor_id, respostas_json}`
- `setores` (BIGINT), `empresas` (BIGINT), `profiles`, `escalas_calculadas`
- Vive em `sql/supabase-setup.sql`

### Arquitetura B — Análise (a que as views usam)
- `departments` (UUID), `employees`, `submissions`, `answers`, `categories`, `questions` (UUID), `risk_classifications`
- `category_severity`, `probability_levels`, `risk_matrix`
- Views `vw_pgr_completo`, `vw_resumo_risco_departamento`, `vw_media_por_categoria_setor`, `vw_evolucao_mensal`
- Vive em `sql/supabase-copsoq.sql` + `sql/supabase-matriz-risco.sql`

**Consequência:** as respostas dos colaboradores nunca chegam nas views. Os painéis mostram zero (ou mock). É esse o bug raiz.

Além disso, a lógica COPSOQ precisa de correções conceituais:
1. Fórmula de conversão da escala 1-5 com inversão só para itens negativos
2. Classificação NR-01 em 5 níveis (Baixo / Tolerável / Moderado / Significativo / Intolerável) via matriz probabilidade × severidade
3. Segmentação por setor (hoje a view PGR consolida tudo junto)
4. RLS liberando `INSERT` anônimo (a survey é pública, via QR code)

---

## 2. Objetivos

1. **Ter uma única fonte de verdade** entre coleta e análise — o que o colaborador responde alimenta direto os painéis.
2. **Preservar o multi-tenant** existente (empresas, gestores, SuperAdmin) sem regressão.
3. **Preservar o front-end atual** (SuperAdmin, Dashboard, Overview, PGR PDF) sem reescrever páginas — usar views-ponte com os nomes antigos.
4. **Implementar a lógica COPSOQ II correta**: conversão 1-5, inversão de itens reversos, médias por subescala, classificação NR-01.
5. **Suportar coleta anônima** via QR code (sem login do colaborador).

## 3. Não-Objetivos

- Não migrar dados históricos (o banco atual está vazio ou com mock; não há nada a preservar).
- Não tocar nas páginas de login, configurações, financeiro ou relatórios históricos.
- Não alterar a matriz NR-01 nem a lógica do PDF PGR em si (`src/lib/generatePGR.ts`) — só garantir que ele receba os dados corretos.
- Não implementar a regra COPSOQ de "50% de dados ausentes" nesta fase (pode entrar depois).

---

## 4. Arquitetura Proposta

Uma única cadeia limpa, do QR code até o PDF:

```
Colaborador → /survey?setor=<id> → insert_survey_response() → respondents + responses
                                                                    ↓
                                  v_converted_responses (aplica inversão 6-x)
                                                                    ↓
                                  v_subscale_averages (média 1-5 por subescala por respondente)
                                                                    ↓
                                         ┌──────────┴──────────┐
                                         ↓                     ↓
                             v_pgr_report               v_risk_levels
                          (NR-01 por setor)         (perfil individual)
                                         ↓
                    views-ponte (vw_pgr_completo, vw_*) → dashboard.ts → UI
```

---

## 5. Mudanças no Schema

### 5.1 DROP (tabelas e views obsoletas)

**Descoberta importante durante a exploração:** no código real, os setores das empresas moram em `departments` (UUID), não em `setores` (BIGINT). A tabela `setores` do `supabase-setup.sql` é legado inutilizado. O QR code do `NewClientPage`/`SuperAdminPage` aponta para `/survey?setor=<departments.id>` — ou seja, uma UUID.

Na ordem correta (FKs primeiro):

```sql
-- Views antigas
DROP VIEW IF EXISTS vw_respostas_completas CASCADE;
DROP VIEW IF EXISTS vw_media_por_categoria_setor CASCADE;
DROP VIEW IF EXISTS vw_pgr_completo CASCADE;
DROP VIEW IF EXISTS vw_resumo_risco_departamento CASCADE;
DROP VIEW IF EXISTS vw_evolucao_mensal CASCADE;

-- Tabelas COPSOQ antigas (o dado nunca foi populado por nenhum fluxo real)
DROP TABLE IF EXISTS answers CASCADE;
DROP TABLE IF EXISTS submissions CASCADE;
DROP TABLE IF EXISTS employees CASCADE;
DROP TABLE IF EXISTS questions CASCADE;       -- será recriada com schema novo
DROP TABLE IF EXISTS categories CASCADE;
DROP TABLE IF EXISTS risk_classifications CASCADE;
DROP TABLE IF EXISTS category_severity CASCADE;
DROP TABLE IF EXISTS probability_levels CASCADE;
DROP TABLE IF EXISTS risk_matrix CASCADE;

-- Tabelas legadas da arquitetura A (nunca integradas)
DROP TABLE IF EXISTS respostas_brutas CASCADE;
DROP TABLE IF EXISTS escalas_calculadas CASCADE;
DROP TABLE IF EXISTS setores CASCADE;          -- substituída por departments (UUID)
```

Ficam preservadas: `empresas`, `profiles`, **`departments`** (esta é a tabela de setores real do sistema).

### 5.2 CREATE — Tabelas novas

```sql
-- Perguntas COPSOQ II (referência fixa)
CREATE TABLE questions (
  id            SMALLINT PRIMARY KEY,            -- 1 a 76
  subscale      TEXT     NOT NULL,
  question_text TEXT     NOT NULL,
  is_inverted   BOOLEAN  NOT NULL DEFAULT FALSE
);

-- Respondentes (anônimos, amarrados ao setor via FK)
CREATE TABLE respondents (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  department_id UUID        NOT NULL REFERENCES departments(id) ON DELETE CASCADE,
  role          TEXT,                                -- opcional
  gender        CHAR(2)     CHECK (gender IN ('M','F','NB','NI')),
  age           SMALLINT    CHECK (age IS NULL OR (age > 0 AND age < 120)),
  created_at    TIMESTAMPTZ DEFAULT now()
);

-- Respostas (uma linha por pergunta por respondente)
CREATE TABLE responses (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  respondent_id UUID        NOT NULL REFERENCES respondents(id) ON DELETE CASCADE,
  question_id   SMALLINT    NOT NULL REFERENCES questions(id),
  value         SMALLINT    NOT NULL CHECK (value BETWEEN 1 AND 5),
  created_at    TIMESTAMPTZ DEFAULT now(),
  UNIQUE (respondent_id, question_id)
);

CREATE INDEX idx_responses_respondent ON responses(respondent_id);
CREATE INDEX idx_responses_question   ON responses(question_id);
CREATE INDEX idx_respondents_dept     ON respondents(department_id);
CREATE INDEX idx_respondents_created  ON respondents(created_at);

-- Catálogo PGR: para cada subescala, a descrição técnica do perigo,
-- as consequências e a ação de controle recomendada.
-- Serve como "dicionário de respostas do PGR" — o relatório final
-- não exibe apenas o nome da subescala, mas sim conteúdo acionável.
CREATE TABLE pgr_actions (
  subscale           TEXT PRIMARY KEY,   -- mesma grafia das subscales em questions
  danger_description TEXT NOT NULL,
  consequences       TEXT NOT NULL,
  control_action     TEXT NOT NULL,
  status             TEXT DEFAULT 'Pendente',
  updated_at         TIMESTAMPTZ DEFAULT now()
);
```

### 5.3a Seed de `pgr_actions` (29 subescalas)

Uma linha por subescala COPSOQ II com o trio **perigo → consequência → ação de controle** redigido pela Noemi. Cobre as 29 dimensões: Exigências Quantitativas, Ritmo de Trabalho, Exigências Cognitivas, Exigências Emocionais, Influência no Trabalho, Possibilidade de Desenvolvimento, Previsibilidade, Transparência do Papel Laboral, Recompensas, Conflitos Laborais, Apoio Social de Colegas, Apoio Social de Superiores, Comunidade Social no Trabalho, Qualidade da Liderança, Confiança Horizontal, Confiança Vertical, Justiça e Respeito, Auto Eficácia, Significado do Trabalho, Compromisso com o Local de Trabalho, Satisfação no Trabalho, Insegurança Laboral, Saúde Geral, Conflito Trabalho/Família, Problemas para Dormir, Burnout, Stress, Sintomas Depressivos, Comportamentos Ofensivos.

O bloco completo de `INSERT ... ON CONFLICT (subscale) DO UPDATE` já foi redigido pela Noemi e será colado integralmente no arquivo de migração (textos de cada linha: ver mensagem do dia 2026-04-10 no histórico do projeto). O `ON CONFLICT ... DO UPDATE` permite rodar o mesmo SQL várias vezes sem duplicar — facilita iterar no texto depois.

**Importante:** a grafia da `subscale` em `pgr_actions` precisa ser **idêntica** à usada na tabela `questions` (Title Case — ex.: `Exigências Quantitativas`, não `EXIGÊNCIAS QUANTITATIVAS`). A view `vw_pgr_completo` faz JOIN por esse texto.

### 5.3 Seed das 76 perguntas

76 `INSERT`s em `questions`:
- **id:** 1 a 76
- **question_text:** extraído do `sql/supabase-copsoq.sql` atual (já tem os textos em português). Converter tudo para minúsculas/título na apresentação; manter a formulação.
- **subscale:** em **Title Case** (não caixa alta), exatamente como usado nas views `v_risk_levels` — ex.: `'Exigências Quantitativas'`, `'Influência no Trabalho'`, `'Qualidade da Liderança'`. Isso é importante porque `v_risk_levels` depende desses nomes literais nos `FILTER`s.
- **is_inverted:** usar o **mapeamento item-a-item** da última proposta da Noemi (não o bulk do SQL atual, que é menos preciso). As nuances importantes:
  - Possibilidade de Desenvolvimento: Q13 `FALSE`, Q14-Q15 `TRUE`
  - Confiança Horizontal: Q40-Q41 `FALSE`, Q42 `TRUE`
  - Confiança Vertical: Q43-Q44 `TRUE`, Q45 `FALSE`
  - Compromisso com o Local de Trabalho: Q54 `TRUE`, Q55 `FALSE`
  - Demais subescalas: conforme mapeamento padrão COPSOQ II (exigências e sintomas → `FALSE`; fatores protetores → `TRUE`).

### 5.4 Views da análise

```sql
-- View 1: Respostas convertidas (aplica 6 - valor nas invertidas)
CREATE VIEW v_converted_responses AS
SELECT
  r.respondent_id,
  r.question_id,
  q.subscale,
  q.is_inverted,
  r.value AS raw_value,
  CASE WHEN q.is_inverted THEN (6 - r.value) ELSE r.value END AS converted_value
FROM responses r
JOIN questions q ON q.id = r.question_id;

-- View 2: Média por subescala por respondente (escala 1-5)
CREATE VIEW v_subscale_averages AS
SELECT
  rsp.id                                      AS respondent_id,
  rsp.department_id,
  cr.subscale,
  ROUND(AVG(cr.converted_value)::NUMERIC, 4)  AS avg_score
FROM v_converted_responses cr
JOIN respondents rsp ON rsp.id = cr.respondent_id
GROUP BY rsp.id, rsp.department_id, cr.subscale;

-- View 3: Relatório PGR (NR-01), POR SETOR e POR SUBESCALA
CREATE VIEW v_pgr_report AS
WITH por_setor AS (
  SELECT department_id, COUNT(DISTINCT id) AS total_respondentes
  FROM respondents
  GROUP BY department_id
),
exposed AS (
  SELECT
    sa.department_id,
    sa.subscale,
    COUNT(*) FILTER (WHERE sa.avg_score >= 3.6) AS n_exposed,
    ROUND(AVG(sa.avg_score)::NUMERIC, 2)        AS media_subescala
  FROM v_subscale_averages sa
  GROUP BY sa.department_id, sa.subscale
),
calc AS (
  SELECT
    e.department_id,
    e.subscale,
    e.media_subescala,
    ps.total_respondentes,
    e.n_exposed,
    ROUND(e.n_exposed::NUMERIC / NULLIF(ps.total_respondentes, 0), 4) AS incidence,
    CASE
      WHEN e.n_exposed::NUMERIC / NULLIF(ps.total_respondentes, 0) <= 0.10 THEN 1
      WHEN e.n_exposed::NUMERIC / NULLIF(ps.total_respondentes, 0) <= 0.30 THEN 2
      WHEN e.n_exposed::NUMERIC / NULLIF(ps.total_respondentes, 0) <= 0.60 THEN 3
      WHEN e.n_exposed::NUMERIC / NULLIF(ps.total_respondentes, 0) <= 0.80 THEN 4
      ELSE 5
    END AS probability,
    4 AS severity  -- fixo, conforme planilha original COPSOQ/PGR
  FROM exposed e
  JOIN por_setor ps ON ps.department_id = e.department_id
)
SELECT
  department_id,
  subscale,
  media_subescala,
  total_respondentes,
  n_exposed,
  incidence,
  probability,
  severity,
  (probability * severity) AS risk_grade,
  CASE
    WHEN probability * severity <= 4  THEN 'Baixo'
    WHEN probability * severity <= 8  THEN 'Tolerável'
    WHEN probability * severity <= 12 THEN 'Moderado'
    WHEN probability * severity <= 16 THEN 'Significativo'
    ELSE                                    'Intolerável'
  END AS risk_classification
FROM calc;

-- View 4: Nível de risco individual (agrupado em 6 dimensões COPSOQ)
CREATE VIEW v_risk_levels AS
WITH pivot AS (
  SELECT
    sa.respondent_id,
    sa.department_id,
    AVG(avg_score) FILTER (WHERE subscale IN ('Exigências Quantitativas','Ritmo de Trabalho'))
      AS demandas_quantitativas,
    AVG(avg_score) FILTER (WHERE subscale IN ('Exigências Cognitivas','Exigências Emocionais'))
      AS demandas_cognitivas,
    AVG(avg_score) FILTER (WHERE subscale IN (
      'Influência no Trabalho','Possibilidade de Desenvolvimento',
      'Previsibilidade','Transparência do Papel Laboral'))
      AS controle_trabalho,
    AVG(avg_score) FILTER (WHERE subscale IN (
      'Apoio Social de Colegas','Comunidade Social no Trabalho'))
      AS suporte_colegas,
    AVG(avg_score) FILTER (WHERE subscale IN (
      'Qualidade da Liderança','Apoio Social de Superiores','Confiança Vertical'))
      AS lideranca,
    AVG(avg_score) FILTER (WHERE subscale IN (
      'Justiça e Respeito','Confiança Horizontal','Recompensas'))
      AS justica_organizacional
  FROM v_subscale_averages sa
  GROUP BY sa.respondent_id, sa.department_id
)
SELECT
  p.*,
  CASE WHEN demandas_quantitativas < 3 THEN 'Baixo'
       WHEN demandas_quantitativas < 4 THEN 'Moderado' ELSE 'Alto' END AS risco_demandas_quantitativas,
  CASE WHEN demandas_cognitivas    < 3 THEN 'Baixo'
       WHEN demandas_cognitivas    < 4 THEN 'Moderado' ELSE 'Alto' END AS risco_demandas_cognitivas,
  CASE WHEN controle_trabalho      < 3 THEN 'Baixo'
       WHEN controle_trabalho      < 4 THEN 'Moderado' ELSE 'Alto' END AS risco_controle_trabalho,
  CASE WHEN suporte_colegas        < 3 THEN 'Baixo'
       WHEN suporte_colegas        < 4 THEN 'Moderado' ELSE 'Alto' END AS risco_suporte_colegas,
  CASE WHEN lideranca              < 3 THEN 'Baixo'
       WHEN lideranca              < 4 THEN 'Moderado' ELSE 'Alto' END AS risco_lideranca,
  CASE WHEN justica_organizacional < 3 THEN 'Baixo'
       WHEN justica_organizacional < 4 THEN 'Moderado' ELSE 'Alto' END AS risco_justica_organizacional
FROM pivot p;
```

### 5.5 Views-ponte (compatibilidade com o front-end existente)

O `src/services/dashboard.ts` espera estas views e colunas específicas. Em vez de reescrever o front, criamos views com os nomes antigos que leem das novas:

```sql
-- Ponte 1: vw_pgr_completo (usada por DashboardPage e generatePGR)
-- JOIN com pgr_actions puxa os textos reais de perigo/consequência/ação de controle
CREATE VIEW vw_pgr_completo AS
SELECT
  d.empresa_id,
  (SELECT COUNT(*) FROM respondents r WHERE r.department_id = d.id) AS qtd_funcionarios,
  d.name                                        AS grupo_homogeneo,
  'Psicossocial'                                AS natureza_perigo,
  -- Conteúdo real vindo de pgr_actions (fallback para o nome da subescala se faltar linha)
  COALESCE(pa.danger_description, pr.subscale)  AS descricao_perigo,
  pa.consequences                               AS consequencias,
  pr.subscale                                   AS subescala,
  pr.n_exposed                                  AS trabalhadores_expostos,
  (ROUND(pr.incidence * 100) || '%')            AS incidencia,
  pr.probability                                AS probabilidade,
  pr.severity                                   AS severidade,
  pr.risk_grade                                 AS grau_risco,
  pr.risk_classification                        AS classificacao_risco,
  COALESCE(
    pa.control_action,
    CASE pr.risk_classification
      WHEN 'Baixo'         THEN 'Ações administrativas'
      WHEN 'Tolerável'     THEN 'Monitoramento contínuo'
      WHEN 'Moderado'      THEN 'Planejar ações de controle'
      WHEN 'Significativo' THEN 'Medidas prioritárias'
      WHEN 'Intolerável'   THEN 'Medidas urgentes e imediatas'
    END
  )                                             AS medidas_controle,
  COALESCE(pa.status, 'Pendente')               AS status,
  -- Converte a média 1-5 para 0-100 (front espera 0-100)
  ROUND(((pr.media_subescala - 1) / 4.0) * 100, 1) AS score_medio,
  pr.total_respondentes                         AS total_respondentes,
  CASE pr.risk_classification
    WHEN 'Baixo'         THEN '#22c55e'
    WHEN 'Tolerável'     THEN '#eab308'
    WHEN 'Moderado'      THEN '#f97316'
    WHEN 'Significativo' THEN '#ef4444'
    WHEN 'Intolerável'   THEN '#991b1b'
  END                                           AS cor_hex
FROM v_pgr_report pr
JOIN departments d       ON d.id = pr.department_id
LEFT JOIN pgr_actions pa ON pa.subscale = pr.subscale;

-- Ponte 2: vw_resumo_risco_departamento (usada por OverviewPage)
CREATE VIEW vw_resumo_risco_departamento AS
SELECT
  empresa_id,
  grupo_homogeneo,
  qtd_funcionarios,
  COUNT(*)                                                                   AS total_categorias,
  COUNT(*) FILTER (WHERE classificacao_risco = 'Baixo')                      AS qtd_baixo,
  COUNT(*) FILTER (WHERE classificacao_risco = 'Tolerável')                  AS qtd_toleravel,
  COUNT(*) FILTER (WHERE classificacao_risco = 'Moderado')                   AS qtd_moderado,
  COUNT(*) FILTER (WHERE classificacao_risco = 'Significativo')              AS qtd_significativo,
  COUNT(*) FILTER (WHERE classificacao_risco = 'Intolerável')                AS qtd_intoleravel,
  CASE
    WHEN COUNT(*) FILTER (WHERE classificacao_risco = 'Intolerável')   > 0 THEN 'Intolerável'
    WHEN COUNT(*) FILTER (WHERE classificacao_risco = 'Significativo') > 0 THEN 'Significativo'
    WHEN COUNT(*) FILTER (WHERE classificacao_risco = 'Moderado')      > 0 THEN 'Moderado'
    WHEN COUNT(*) FILTER (WHERE classificacao_risco = 'Tolerável')     > 0 THEN 'Tolerável'
    ELSE                                                                    'Baixo'
  END AS risco_global
FROM vw_pgr_completo
GROUP BY empresa_id, grupo_homogeneo, qtd_funcionarios;

-- Ponte 3: vw_media_por_categoria_setor (Top riscos)
CREATE VIEW vw_media_por_categoria_setor AS
SELECT
  d.empresa_id,
  d.id                                               AS department_id,
  d.name                                             AS department_name,
  pr.subscale                                        AS category_name,
  ROUND(((pr.media_subescala - 1) / 4.0) * 100, 1)   AS score_medio,
  CASE pr.risk_classification
    WHEN 'Baixo'         THEN 'Green'
    WHEN 'Tolerável'     THEN 'Green'
    WHEN 'Moderado'      THEN 'Yellow'
    WHEN 'Significativo' THEN 'Red'
    WHEN 'Intolerável'   THEN 'Red'
  END                                                AS semaforo_cor,
  CASE pr.risk_classification
    WHEN 'Baixo'         THEN '#22c55e'
    WHEN 'Tolerável'     THEN '#eab308'
    WHEN 'Moderado'      THEN '#f97316'
    WHEN 'Significativo' THEN '#ef4444'
    WHEN 'Intolerável'   THEN '#991b1b'
  END                                                AS cor_hex
FROM v_pgr_report pr
JOIN departments d ON d.id = pr.department_id;

-- Ponte 4: vw_evolucao_mensal (gráfico temporal)
CREATE VIEW vw_evolucao_mensal AS
SELECT
  d.empresa_id,
  DATE_TRUNC('month', rsp.created_at)::DATE                           AS mes,
  COUNT(DISTINCT rsp.id)                                              AS total_respondentes,
  ROUND(((AVG(cr.converted_value) - 1) / 4.0 * 100)::NUMERIC, 1)      AS score_medio
FROM v_converted_responses cr
JOIN respondents rsp ON rsp.id = cr.respondent_id
JOIN departments d   ON d.id = rsp.department_id
GROUP BY d.empresa_id, DATE_TRUNC('month', rsp.created_at)
ORDER BY mes ASC;
```

**Nota sobre escala:** as views-ponte convertem a média 1-5 para 0-100 com `((avg-1)/4)*100`, porque o front-end e o PDF PGR foram construídos esperando score 0-100. A conversão preserva o comportamento visual.

### 5.6 Função RPC de inserção

```sql
CREATE OR REPLACE FUNCTION insert_survey_response(
  p_department_id UUID,
  p_answers       JSONB   -- formato: {"1": 4, "2": 3, ..., "76": 5}
) RETURNS UUID
LANGUAGE plpgsql AS $$
DECLARE
  v_respondent_id UUID;
  v_key           TEXT;
  v_value         INT;
BEGIN
  INSERT INTO respondents (department_id) VALUES (p_department_id)
  RETURNING id INTO v_respondent_id;

  FOR v_key, v_value IN SELECT key, value::INT FROM jsonb_each_text(p_answers)
  LOOP
    INSERT INTO responses (respondent_id, question_id, value)
    VALUES (v_respondent_id, v_key::SMALLINT, v_value);
  END LOOP;

  RETURN v_respondent_id;
END;
$$;
```

### 5.7 Row-Level Security

```sql
ALTER TABLE questions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE respondents  ENABLE ROW LEVEL SECURITY;
ALTER TABLE responses    ENABLE ROW LEVEL SECURITY;
ALTER TABLE pgr_actions  ENABLE ROW LEVEL SECURITY;

-- questions: leitura pública (a survey precisa listar)
CREATE POLICY "questions_public_read" ON questions FOR SELECT USING (true);

-- pgr_actions: leitura pública (autenticados leem via view, mas é catálogo)
CREATE POLICY "pgr_actions_public_read" ON pgr_actions FOR SELECT USING (true);
-- Só admin atualiza o conteúdo do catálogo
CREATE POLICY "pgr_actions_admin_write" ON pgr_actions FOR ALL USING (
  EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin')
);

-- respondents/responses: INSERT anônimo (QR code sem login)
CREATE POLICY "respondents_anon_insert" ON respondents
  FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "responses_anon_insert" ON responses
  FOR INSERT TO anon WITH CHECK (true);

-- Permitir que anon execute a função RPC
GRANT EXECUTE ON FUNCTION insert_survey_response(UUID, JSONB) TO anon;

-- Autenticados leem tudo (para dashboards)
CREATE POLICY "respondents_auth_read" ON respondents
  FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "responses_auth_read" ON responses
  FOR SELECT USING (auth.role() = 'authenticated');
```

---

## 6. Mudanças no Front-end

Dois arquivos mudam de verdade (`survey.ts`, `empresas.ts`) e um ajuste pequeno em `SurveyPage.tsx`.

### 6.1 `src/services/survey.ts` — reescrever

```ts
import { supabase } from '../lib/supabase';

export interface Question {
  id: number;              // era string (UUID), agora SMALLINT
  question_text: string;
  subscale: string;        // era category_name
  is_inverted: boolean;
}

export async function fetchQuestions(): Promise<Question[]> {
  const { data, error } = await supabase
    .from('questions')
    .select('id, question_text, subscale, is_inverted')
    .order('id', { ascending: true });
  if (error) throw error;
  if (!data?.length) throw new Error('Nenhuma pergunta encontrada');
  return data as Question[];
}

// setorId continua sendo UUID (departments.id) — não muda no QR code
export async function submitSurveyResponse(
  setorId: string,
  answers: Record<number, number>
) {
  const { error } = await supabase.rpc('insert_survey_response', {
    p_department_id: setorId,
    p_answers:       answers,   // { 1: 4, 2: 3, ... }
  });
  if (error) throw error;
}
```

### 6.2 `src/pages/SurveyPage.tsx` — ajustes de tipo pequenos

- `question.id` hoje é usado como **string** (UUID) em chaves de mapa. Passa a ser **number**. Uns 3-4 lugares para trocar o tipo.
- O estado `answers` passa de `Record<string, number>` para `Record<number, number>`.
- A querystring `?setor=<id>` **continua sendo UUID** (nenhuma mudança aí — o QR code continua idêntico).

### 6.3 `src/services/empresas.ts` — rewritar 2 funções

Estas duas funções hoje leem das tabelas `employees` e `submissions` que serão dropadas. A `SuperAdminPage` usa elas para contar colaboradores e mostrar quando foi a última submissão. Precisam ser reescritas para usar `respondents`:

```ts
// Antes: lia de 'employees' com join em 'departments'
// Depois: agrega respondents por empresa via departments
export async function fetchEmployeesByEmpresa() {
  const { data, error } = await supabase
    .from('respondents')
    .select('id, department_id, departments(empresa_id)');
  if (error) throw error;
  return data || [];
}

// Antes: lia de 'submissions' com join aninhado
// Depois: usa created_at de respondents (cada respondent é uma "submissão")
export async function fetchSubmissionsWithEmpresa() {
  const { data, error } = await supabase
    .from('respondents')
    .select('created_at, departments(empresa_id)')
    .order('created_at', { ascending: false });
  if (error) throw error;
  // Renomeia created_at → submitted_at para manter o shape esperado
  return (data || []).map((r: any) => ({
    submitted_at: r.created_at,
    employees:    { departments: r.departments },   // preserva shape aninhado
  }));
}
```

As demais funções (`fetchEmpresas`, `createEmpresa`, `fetchDepartments`, `createDepartments`, `fetchAlertasCriticos`, `fetchFatoresCopsoq`, `createGestorUser`) **não mudam** — continuam batendo em `empresas`, `departments` ou nas views-ponte.

### 6.4 O que NÃO muda

- `dashboard.ts` — continua lendo `vw_pgr_completo`, `vw_resumo_risco_departamento`, `vw_media_por_categoria_setor`, `vw_evolucao_mensal`. As views-ponte entregam os mesmos campos.
- `generatePGR.ts` — continua recebendo `PgrRow[]` com a mesma forma.
- OverviewPage, DashboardPage, SuperAdminPage, SetoresPage, NewClientPage, páginas admin — intocadas.
- QR codes — já apontam para `/survey?setor=<uuid>`; continua sendo `departments.id`.

### 6.5 Nota: drift do schema `empresas`

Durante a exploração achei que `src/services/empresas.ts` seleciona `id, nome_fantasia, cnpj, data_cadastro`, mas o `sql/supabase-setup.sql` define `empresas` com `nome, cnpj, logo_url, created_at`. Ou seja, o banco real já foi alterado fora do controle de versão. **Este spec não toca em `empresas`** — quem alterou acerta depois. Só registro o drift aqui para ficar documentado.

---

## 7. Ordem de Execução da Migração

1. Escrever um único arquivo SQL novo: `sql/2026-04-10-copsoq-redesign.sql` com todo o conteúdo da seção 5.
2. Rodar esse SQL no editor do Supabase (o DROP é seguro porque o banco não tem dados relevantes).
3. Atualizar `src/services/survey.ts` e `src/pages/SurveyPage.tsx`.
4. Testar o fluxo completo: abrir `/survey?setor=<id>`, responder 76 perguntas, verificar que chega em `respondents` + `responses`, abrir `/dashboard` e `/overview` e ver os scores.
5. Gerar o PDF PGR pelo botão do DashboardPage para confirmar que o `generatePGR` ainda funciona.
6. Commit em etapas: (a) SQL + migração, (b) front-end, (c) testes/dados demo.

---

## 8. Riscos e Considerações

- **Escala no front esperava 0-100, as views internas usam 1-5.** As views-ponte fazem a conversão. Se alguém mexer direto nas views novas, precisa lembrar disso.
- **Severidade fixa em 4.** Seguindo a planilha COPSOQ original. Se a consultoria quiser modular severidade por subescala no futuro, isso vira uma tabela `severidade_por_subscale`.
- **Threshold de "exposto" = 3.6.** Em escala 1-5 equivale a ~65% — o padrão COPSOQ para "frequentemente". Está hardcoded dentro da view; pode virar configuração depois.
- **Sem regra dos 50% de dados ausentes (COPSOQ clássico).** Fica para uma fase 2. Por enquanto, uma pessoa que responde pouco vira um respondente com médias parciais.
- **Dados demo antigos (`sql/supabase-dados-demo.sql`) ficam obsoletos.** Podemos reescrever depois ou simplesmente deixar de lado.

---

## 9. Critério de Sucesso

- Colaborador responde o QR code → aparece uma linha em `respondents` e 76 em `responses`.
- `SELECT * FROM vw_pgr_completo` retorna linhas reais (não zero).
- DashboardPage mostra cards dos setores com risco calculado.
- OverviewPage mostra KPIs, top riscos e evolução mensal com dados reais.
- Botão "Gerar Relatório PGR" produz um PDF com os setores e suas classificações NR-01.
- Nenhuma regressão visual nas páginas que não foram tocadas.
