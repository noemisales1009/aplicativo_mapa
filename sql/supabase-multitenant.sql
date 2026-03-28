-- ============================================
-- MULTI-TENANCY: Atualizar views para incluir empresa_id
-- Cada empresa vê somente seus dados
-- Admin (dona do SaaS) vê tudo
-- ============================================

-- 0. Dropar views existentes (ordem de dependência)
DROP VIEW IF EXISTS vw_resumo_risco_departamento CASCADE;
DROP VIEW IF EXISTS vw_pgr_completo CASCADE;
DROP VIEW IF EXISTS vw_media_por_categoria_setor CASCADE;
DROP VIEW IF EXISTS vw_respostas_completas CASCADE;

-- 1. View: Respostas completas (com empresa_id)
CREATE OR REPLACE VIEW vw_respostas_completas AS
SELECT
  d.empresa_id,
  e.id AS employee_id, e.name AS employee_name,
  d.id AS department_id, d.name AS department_name,
  s.id AS submission_id, s.submitted_at,
  q.question_number, q.question_text, q.is_inverted,
  c.id AS category_id, c.name AS category_name,
  a.score AS score_original,
  CASE WHEN q.is_inverted=false THEN ROUND(((a.score-1)::NUMERIC/4)*100) ELSE ROUND(((5-a.score)::NUMERIC/4)*100) END AS score_0_100,
  rc.risk_category AS semaforo_cor, rc.risk_level AS semaforo_nivel, rc.action_required AS acao_recomendada
FROM answers a
  JOIN submissions s ON a.submission_id=s.id JOIN employees e ON s.employee_id=e.id
  JOIN departments d ON e.department_id=d.id JOIN questions q ON a.question_id=q.id
  JOIN categories c ON q.category_id=c.id
  LEFT JOIN risk_classifications rc ON rc.category_id=c.id
    AND (CASE WHEN q.is_inverted=false THEN ROUND(((a.score-1)::NUMERIC/4)*100) ELSE ROUND(((5-a.score)::NUMERIC/4)*100) END) >= rc.min_score
    AND (CASE WHEN q.is_inverted=false THEN ROUND(((a.score-1)::NUMERIC/4)*100) ELSE ROUND(((5-a.score)::NUMERIC/4)*100) END) <= rc.max_score;

-- 2. View: Média por categoria/setor (com empresa_id)
CREATE OR REPLACE VIEW vw_media_por_categoria_setor AS
WITH medias AS (
  SELECT d.empresa_id, d.id AS department_id, d.name AS department_name, c.id AS category_id, c.name AS category_name,
    ROUND(AVG(CASE WHEN q.is_inverted=false THEN ((a.score-1)::NUMERIC/4)*100 ELSE ((5-a.score)::NUMERIC/4)*100 END),1) AS score_medio,
    COUNT(DISTINCT s.id) AS total_submissions, COUNT(DISTINCT s.employee_id) AS total_respondentes
  FROM answers a JOIN submissions s ON a.submission_id=s.id JOIN employees e ON s.employee_id=e.id
    JOIN departments d ON e.department_id=d.id JOIN questions q ON a.question_id=q.id JOIN categories c ON q.category_id=c.id
  GROUP BY d.empresa_id, d.id, d.name, c.id, c.name
)
SELECT m.*, rc.risk_category AS semaforo_cor, rc.risk_level AS semaforo_nivel, rc.action_required AS acao_recomendada,
  CASE rc.risk_category WHEN 'Green' THEN '#22c55e' WHEN 'Yellow' THEN '#eab308' WHEN 'Red' THEN '#ef4444' END AS cor_hex
FROM medias m LEFT JOIN risk_classifications rc ON rc.category_id=m.category_id AND m.score_medio>=rc.min_score AND m.score_medio<=rc.max_score;

-- 3. View: PGR completo (com empresa_id)
CREATE OR REPLACE VIEW vw_pgr_completo AS
WITH scores AS (
  SELECT d.empresa_id, d.id AS department_id, d.name AS department_name, c.id AS category_id, c.name AS category_name,
    (SELECT COUNT(*) FROM employees e2 WHERE e2.department_id=d.id) AS qtd_funcionarios,
    COUNT(DISTINCT s.employee_id) FILTER (WHERE a.score>=4) AS trabalhadores_expostos,
    COUNT(DISTINCT s.employee_id) AS total_respondentes,
    ROUND(AVG(CASE WHEN q.is_inverted=false THEN ((a.score-1)::NUMERIC/4)*100 ELSE ((5-a.score)::NUMERIC/4)*100 END),1) AS score_medio
  FROM answers a JOIN submissions s ON a.submission_id=s.id JOIN employees e ON s.employee_id=e.id
    JOIN departments d ON e.department_id=d.id JOIN questions q ON a.question_id=q.id JOIN categories c ON q.category_id=c.id
  GROUP BY d.empresa_id, d.id, d.name, c.id, c.name
)
SELECT sc.empresa_id, sc.qtd_funcionarios, sc.department_name AS grupo_homogeneo, 'Psicossocial' AS natureza_perigo,
  sc.category_name AS descricao_perigo, sc.trabalhadores_expostos,
  CASE WHEN sc.total_respondentes>0 THEN ROUND((sc.trabalhadores_expostos::NUMERIC/sc.total_respondentes)*100)||'%' ELSE '0%' END AS incidencia,
  pl.level AS probabilidade, cs.severity_level AS severidade, rm.risk_score AS grau_risco,
  rm.risk_grade AS classificacao_risco,
  CASE rm.risk_grade WHEN 'Baixo' THEN 'Ações administrativas' WHEN 'Tolerável' THEN 'Monitoramento contínuo'
    WHEN 'Moderado' THEN 'Planejar ações de controle' WHEN 'Significativo' THEN 'Medidas prioritárias'
    WHEN 'Intolerável' THEN 'Medidas urgentes e imediatas' END AS medidas_controle,
  'Pendente' AS status, sc.score_medio, sc.total_respondentes,
  CASE rm.risk_grade WHEN 'Baixo' THEN '#22c55e' WHEN 'Tolerável' THEN '#eab308' WHEN 'Moderado' THEN '#f97316'
    WHEN 'Significativo' THEN '#ef4444' WHEN 'Intolerável' THEN '#991b1b' END AS cor_hex
FROM scores sc
  JOIN category_severity cs ON sc.category_id=cs.category_id
  JOIN probability_levels pl ON sc.score_medio>=pl.score_min AND sc.score_medio<=pl.score_max
  JOIN risk_matrix rm ON pl.level=rm.probability_level AND cs.severity_level=rm.severity_level;

-- 4. View: Resumo por setor (com empresa_id)
CREATE OR REPLACE VIEW vw_resumo_risco_departamento AS
SELECT empresa_id, grupo_homogeneo, qtd_funcionarios, COUNT(*) AS total_categorias,
  COUNT(*) FILTER (WHERE classificacao_risco='Baixo') AS qtd_baixo,
  COUNT(*) FILTER (WHERE classificacao_risco='Tolerável') AS qtd_toleravel,
  COUNT(*) FILTER (WHERE classificacao_risco='Moderado') AS qtd_moderado,
  COUNT(*) FILTER (WHERE classificacao_risco='Significativo') AS qtd_significativo,
  COUNT(*) FILTER (WHERE classificacao_risco='Intolerável') AS qtd_intoleravel,
  CASE WHEN COUNT(*) FILTER (WHERE classificacao_risco='Intolerável')>0 THEN 'Intolerável'
    WHEN COUNT(*) FILTER (WHERE classificacao_risco='Significativo')>0 THEN 'Significativo'
    WHEN COUNT(*) FILTER (WHERE classificacao_risco='Moderado')>0 THEN 'Moderado'
    WHEN COUNT(*) FILTER (WHERE classificacao_risco='Tolerável')>0 THEN 'Tolerável' ELSE 'Baixo' END AS risco_global
FROM vw_pgr_completo GROUP BY empresa_id, grupo_homogeneo, qtd_funcionarios;

-- 5. RLS: departments filtrados por empresa do usuário logado
-- (já existem policies, mas vamos garantir que gestores só vejam seus departamentos)
DROP POLICY IF EXISTS "Gestor sees own empresa departments" ON departments;
CREATE POLICY "Gestor sees own empresa departments" ON departments
  FOR SELECT USING (
    -- Admin vê tudo
    EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin')
    OR
    -- Gestor vê só da empresa dele
    empresa_id = (SELECT empresa_id FROM profiles WHERE profiles.id = auth.uid())
  );

-- 6. RLS: employees filtrados via department
DROP POLICY IF EXISTS "Users see own empresa employees" ON employees;
CREATE POLICY "Users see own empresa employees" ON employees
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin')
    OR
    department_id IN (SELECT id FROM departments WHERE empresa_id = (SELECT empresa_id FROM profiles WHERE profiles.id = auth.uid()))
  );

-- 7. RLS: answers filtrados via submission > employee > department
DROP POLICY IF EXISTS "Users see own empresa answers" ON answers;
CREATE POLICY "Users see own empresa answers" ON answers
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin')
    OR
    submission_id IN (
      SELECT s.id FROM submissions s
      JOIN employees e ON s.employee_id = e.id
      JOIN departments d ON e.department_id = d.id
      WHERE d.empresa_id = (SELECT empresa_id FROM profiles WHERE profiles.id = auth.uid())
    )
  );

-- 8. RLS: submissions filtrados via employee > department
DROP POLICY IF EXISTS "Users see own empresa submissions" ON submissions;
CREATE POLICY "Users see own empresa submissions" ON submissions
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin')
    OR
    employee_id IN (
      SELECT e.id FROM employees e
      JOIN departments d ON e.department_id = d.id
      WHERE d.empresa_id = (SELECT empresa_id FROM profiles WHERE profiles.id = auth.uid())
    )
  );
