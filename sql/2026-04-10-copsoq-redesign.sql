-- ============================================================
-- M.A.P.A. — Redesenho COPSOQ II (2026-04-10)
--
-- Une coleta e análise: respondents + responses alimentam direto
-- as views do dashboard. Implementa a lógica COPSOQ II correta
-- (conversão 1-5 com inversão) e a matriz NR-01 (prob × sev).
--
-- Executar no SQL Editor do Supabase em UM bloco só.
-- Pré-requisitos: tabelas `empresas`, `profiles`, `departments`
-- precisam existir (já estão no banco).
-- ============================================================

-- ------------------------------------------------------------
-- 1. DROP do legado (tabelas e views obsoletas)
-- ------------------------------------------------------------
DROP VIEW IF EXISTS vw_respostas_completas CASCADE;
DROP VIEW IF EXISTS vw_media_por_categoria_setor CASCADE;
DROP VIEW IF EXISTS vw_pgr_completo CASCADE;
DROP VIEW IF EXISTS vw_resumo_risco_departamento CASCADE;
DROP VIEW IF EXISTS vw_evolucao_mensal CASCADE;

DROP TABLE IF EXISTS answers CASCADE;
DROP TABLE IF EXISTS submissions CASCADE;
DROP TABLE IF EXISTS employees CASCADE;
DROP TABLE IF EXISTS questions CASCADE;
DROP TABLE IF EXISTS categories CASCADE;
DROP TABLE IF EXISTS risk_classifications CASCADE;
DROP TABLE IF EXISTS category_severity CASCADE;
DROP TABLE IF EXISTS probability_levels CASCADE;
DROP TABLE IF EXISTS risk_matrix CASCADE;

DROP TABLE IF EXISTS respostas_brutas CASCADE;
DROP TABLE IF EXISTS escalas_calculadas CASCADE;
DROP TABLE IF EXISTS setores CASCADE;

-- ------------------------------------------------------------
-- 2. CREATE TABLE (schema novo)
-- ------------------------------------------------------------

-- Dicionário das 76 perguntas COPSOQ II
CREATE TABLE questions (
  id            SMALLINT PRIMARY KEY,
  subscale      TEXT     NOT NULL,
  question_text TEXT     NOT NULL,
  is_inverted   BOOLEAN  NOT NULL DEFAULT FALSE
);

-- Respondentes anônimos, amarrados ao departamento (setor)
CREATE TABLE respondents (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  department_id UUID        NOT NULL REFERENCES departments(id) ON DELETE CASCADE,
  role          TEXT,
  gender        CHAR(2)     CHECK (gender IN ('M','F','NB','NI')),
  age           SMALLINT    CHECK (age IS NULL OR (age > 0 AND age < 120)),
  created_at    TIMESTAMPTZ DEFAULT now()
);

-- Uma linha por resposta (respondente × pergunta)
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

-- Catálogo PGR: para cada subescala, o conteúdo acionável do relatório
CREATE TABLE pgr_actions (
  subscale           TEXT PRIMARY KEY,
  danger_description TEXT NOT NULL,
  consequences       TEXT NOT NULL,
  control_action     TEXT NOT NULL,
  status             TEXT DEFAULT 'Pendente',
  updated_at         TIMESTAMPTZ DEFAULT now()
);

-- ------------------------------------------------------------
-- 3. VIEWS DE ANÁLISE (escala interna 1-5)
-- ------------------------------------------------------------

-- View 1: Respostas convertidas (aplica 6 - valor nas invertidas)
CREATE OR REPLACE VIEW v_converted_responses AS
SELECT
  r.respondent_id,
  r.question_id,
  q.subscale,
  q.is_inverted,
  r.value AS raw_value,
  CASE WHEN q.is_inverted THEN (6 - r.value) ELSE r.value END AS converted_value
FROM responses r
JOIN questions q ON q.id = r.question_id;

-- View 2: Média por subescala por respondente
CREATE OR REPLACE VIEW v_subscale_averages AS
SELECT
  rsp.id                                      AS respondent_id,
  rsp.department_id,
  cr.subscale,
  ROUND(AVG(cr.converted_value)::NUMERIC, 4)  AS avg_score
FROM v_converted_responses cr
JOIN respondents rsp ON rsp.id = cr.respondent_id
GROUP BY rsp.id, rsp.department_id, cr.subscale;

-- View 3: Relatório PGR (NR-01) por setor × subescala
CREATE OR REPLACE VIEW v_pgr_report AS
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
    4 AS severity
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

-- View 4: Nível de risco individual agrupado em 6 dimensões
CREATE OR REPLACE VIEW v_risk_levels AS
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

-- ------------------------------------------------------------
-- 4. VIEWS-PONTE (compatibilidade com dashboard.ts — escala 0-100)
-- ------------------------------------------------------------

-- Ponte 1: vw_pgr_completo (DashboardPage + generatePGR)
CREATE OR REPLACE VIEW vw_pgr_completo AS
SELECT
  d.empresa_id,
  (SELECT COUNT(*) FROM respondents r WHERE r.department_id = d.id) AS qtd_funcionarios,
  d.name                                        AS grupo_homogeneo,
  'Psicossocial'                                AS natureza_perigo,
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

-- Ponte 2: vw_resumo_risco_departamento (OverviewPage)
CREATE OR REPLACE VIEW vw_resumo_risco_departamento AS
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

-- Ponte 3: vw_media_por_categoria_setor (Top riscos no Overview)
CREATE OR REPLACE VIEW vw_media_por_categoria_setor AS
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

-- Ponte 4: vw_evolucao_mensal (gráfico temporal no Overview)
CREATE OR REPLACE VIEW vw_evolucao_mensal AS
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

-- ------------------------------------------------------------
-- 5. FUNÇÃO RPC — inserção transacional do questionário
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION insert_survey_response(
  p_department_id UUID,
  p_answers       JSONB
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

-- ------------------------------------------------------------
-- 6. ROW-LEVEL SECURITY
-- ------------------------------------------------------------
ALTER TABLE questions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE respondents  ENABLE ROW LEVEL SECURITY;
ALTER TABLE responses    ENABLE ROW LEVEL SECURITY;
ALTER TABLE pgr_actions  ENABLE ROW LEVEL SECURITY;

CREATE POLICY "questions_public_read"   ON questions   FOR SELECT USING (true);
CREATE POLICY "pgr_actions_public_read" ON pgr_actions FOR SELECT USING (true);

CREATE POLICY "pgr_actions_admin_write" ON pgr_actions FOR ALL USING (
  EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin')
);

CREATE POLICY "respondents_anon_insert" ON respondents
  FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "responses_anon_insert"   ON responses
  FOR INSERT TO anon WITH CHECK (true);

GRANT EXECUTE ON FUNCTION insert_survey_response(UUID, JSONB) TO anon;

CREATE POLICY "respondents_auth_read" ON respondents
  FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "responses_auth_read"   ON responses
  FOR SELECT USING (auth.role() = 'authenticated');

-- ============================================================
-- 7. SEED: 76 perguntas COPSOQ II
-- ============================================================
INSERT INTO questions (id, subscale, question_text, is_inverted) VALUES
(1,  'Exigências Quantitativas',            'A sua carga de trabalho acumula-se por ser mal distribuída?', FALSE),
(2,  'Exigências Quantitativas',            'Com que frequência não tem tempo para completar todas as tarefas do seu trabalho?', FALSE),
(3,  'Exigências Quantitativas',            'Precisa fazer horas-extra?', FALSE),
(4,  'Ritmo de Trabalho',                   'Precisa trabalhar muito rapidamente?', FALSE),
(5,  'Exigências Cognitivas',               'O seu trabalho exige a sua atenção constante?', FALSE),
(6,  'Exigências Cognitivas',               'O seu trabalho requer que seja bom a propor novas ideias?', FALSE),
(7,  'Exigências Cognitivas',               'O seu trabalho exige que tome decisões difíceis?', FALSE),
(8,  'Exigências Emocionais',               'O seu trabalho exige emocionalmente de si?', FALSE),
(9,  'Influência no Trabalho',              'Tem um elevado grau de influência no seu trabalho?', TRUE),
(10, 'Influência no Trabalho',              'Participa na escolha das pessoas com quem trabalha?', TRUE),
(11, 'Influência no Trabalho',              'Pode influenciar a quantidade de trabalho que lhe compete a si?', TRUE),
(12, 'Influência no Trabalho',              'Tem alguma influência sobre o tipo de tarefas que faz?', TRUE),
(13, 'Possibilidade de Desenvolvimento',    'O seu trabalho exige que tenha iniciativa?', FALSE),
(14, 'Possibilidade de Desenvolvimento',    'O seu trabalho permite-lhe aprender coisas novas?', TRUE),
(15, 'Possibilidade de Desenvolvimento',    'O seu trabalho permite-lhe usar as suas habilidades ou perícias?', TRUE),
(16, 'Previsibilidade',                     'No seu local de trabalho, é informado com antecedência sobre decisões importantes, mudanças ou planos para o futuro?', TRUE),
(17, 'Previsibilidade',                     'Recebe toda a informação de que necessita para fazer bem o seu trabalho?', TRUE),
(18, 'Transparência do Papel Laboral',      'O seu trabalho apresenta objectivos claros?', TRUE),
(19, 'Transparência do Papel Laboral',      'Sabe exactamente quais as suas responsabilidades?', TRUE),
(20, 'Transparência do Papel Laboral',      'Sabe exactamente o que é esperado de si?', TRUE),
(21, 'Recompensas',                         'O seu trabalho é reconhecido e apreciado pela gerência?', TRUE),
(22, 'Recompensas',                         'A gerência do seu local de trabalho respeita-o?', TRUE),
(23, 'Recompensas',                         'É tratado de forma justa no seu local de trabalho?', TRUE),
(24, 'Conflitos Laborais',                  'Faz coisas no seu trabalho que uns concordam mas outros não?', FALSE),
(25, 'Conflitos Laborais',                  'Por vezes tem que fazer coisas que deveriam ser feitas de outra maneira?', FALSE),
(26, 'Conflitos Laborais',                  'Por vezes tem que fazer coisas que considera desnecessárias?', FALSE),
(27, 'Apoio Social de Colegas',             'Com que frequência tem ajuda e apoio dos seus colegas de trabalho?', TRUE),
(28, 'Apoio Social de Colegas',             'Com que frequência os seus colegas estão dispostos a ouvi-lo(a) sobre os seus problemas de trabalho?', TRUE),
(29, 'Apoio Social de Colegas',             'Com que frequência os seus colegas falam consigo acerca do seu desempenho laboral?', TRUE),
(30, 'Apoio Social de Superiores',          'Com que frequência o seu superior imediato fala consigo sobre como está a decorrer o seu trabalho?', TRUE),
(31, 'Apoio Social de Superiores',          'Com que frequência tem ajuda e apoio do seu superior imediato?', TRUE),
(32, 'Apoio Social de Superiores',          'Com que frequência é que o seu superior imediato fala consigo em relação ao seu desempenho laboral?', TRUE),
(33, 'Comunidade Social no Trabalho',       'Existe um bom ambiente de trabalho entre si e os seus colegas?', TRUE),
(34, 'Comunidade Social no Trabalho',       'Existe uma boa cooperação entre os colegas de trabalho?', TRUE),
(35, 'Comunidade Social no Trabalho',       'No seu local de trabalho sente-se parte de uma comunidade?', TRUE),
(36, 'Qualidade da Liderança',              'A gerência oferece aos indivíduos e ao grupo boas oportunidades de desenvolvimento?', TRUE),
(37, 'Qualidade da Liderança',              'A gerência dá prioridade à satisfação no trabalho?', TRUE),
(38, 'Qualidade da Liderança',              'A gerência é boa no planeamento do trabalho?', TRUE),
(39, 'Qualidade da Liderança',              'A gerência é boa a resolver conflitos?', TRUE),
(40, 'Confiança Horizontal',                'Os funcionários ocultam informações uns dos outros?', FALSE),
(41, 'Confiança Horizontal',                'Os funcionários ocultam informação à gerência?', FALSE),
(42, 'Confiança Horizontal',                'Os funcionários confiam uns nos outros de um modo geral?', TRUE),
(43, 'Confiança Vertical',                  'A gerência confia nos seus funcionários para fazerem o seu trabalho bem?', TRUE),
(44, 'Confiança Vertical',                  'Confia na informação que lhe é transmitida pela gerência?', TRUE),
(45, 'Confiança Vertical',                  'A gerência oculta informação aos seus funcionários?', FALSE),
(46, 'Justiça e Respeito',                  'Os conflitos são resolvidos de uma forma justa?', TRUE),
(47, 'Justiça e Respeito',                  'As sugestões dos funcionários são tratadas de forma séria pela gerência?', TRUE),
(48, 'Justiça e Respeito',                  'O trabalho é igualmente distribuído pelos funcionários?', TRUE),
(49, 'Auto Eficácia',                       'Sou sempre capaz de resolver problemas, se tentar o suficiente.', TRUE),
(50, 'Auto Eficácia',                       'É-me fácil seguir os meus planos e atingir os meus objectivos.', TRUE),
(51, 'Significado do Trabalho',             'O seu trabalho tem algum significado para si?', TRUE),
(52, 'Significado do Trabalho',             'Sente que o seu trabalho é importante?', TRUE),
(53, 'Significado do Trabalho',             'Sente-se motivado e envolvido com o seu trabalho?', TRUE),
(54, 'Compromisso com o Local de Trabalho', 'Gosta de falar com os outros sobre o seu local de trabalho?', TRUE),
(55, 'Compromisso com o Local de Trabalho', 'Sente que os problemas do seu local de trabalho são seus também?', FALSE),
(56, 'Satisfação no Trabalho',              'Relativamente às suas perspectivas de trabalho, quão satisfeito está?', TRUE),
(57, 'Satisfação no Trabalho',              'Relativamente às condições físicas do seu local de trabalho, quão satisfeito está?', TRUE),
(58, 'Satisfação no Trabalho',              'Relativamente à forma como as suas capacidades são utilizadas, quão satisfeito está?', TRUE),
(59, 'Satisfação no Trabalho',              'Relativamente ao seu trabalho de uma forma global, quão satisfeito está?', TRUE),
(60, 'Insegurança Laboral',                 'Sente-se preocupado em ficar desempregado?', FALSE),
(61, 'Saúde Geral',                         'Em geral, como considera a sua saúde?', FALSE),
(62, 'Conflito Trabalho/Família',           'Sente que o seu trabalho lhe exige muita energia que acaba por afectar a sua vida privada negativamente?', FALSE),
(63, 'Conflito Trabalho/Família',           'Sente que o seu trabalho lhe exige muito tempo que acaba por afectar a sua vida privada negativamente?', FALSE),
(64, 'Conflito Trabalho/Família',           'A sua família e os seus amigos dizem-lhe que trabalha demais?', FALSE),
(65, 'Problemas para Dormir',               'Teve dificuldade a adormecer?', FALSE),
(66, 'Problemas para Dormir',               'Acordou várias vezes durante a noite e depois não conseguia adormecer novamente?', FALSE),
(67, 'Burnout',                             'Sentiu-se fisicamente exausto?', FALSE),
(68, 'Burnout',                             'Sentiu-se emocionalmente exausto?', FALSE),
(69, 'Stress',                              'Sentiu-se irritado?', FALSE),
(70, 'Stress',                              'Sentiu-se ansioso?', FALSE),
(71, 'Sintomas Depressivos',                'Sentiu-se triste?', FALSE),
(72, 'Sintomas Depressivos',                'Sentiu falta de interesse por coisas quotidianas?', FALSE),
(73, 'Comportamentos Ofensivos',            'Tem sido alvo de insultos ou provocações verbais?', FALSE),
(74, 'Comportamentos Ofensivos',            'Tem sido exposto a assédio sexual indesejado?', FALSE),
(75, 'Comportamentos Ofensivos',            'Tem sido exposto a ameaças de violência?', FALSE),
(76, 'Comportamentos Ofensivos',            'Tem sido exposto a violência física?', FALSE)
ON CONFLICT (id) DO UPDATE SET
  subscale      = EXCLUDED.subscale,
  question_text = EXCLUDED.question_text,
  is_inverted   = EXCLUDED.is_inverted;

-- ============================================================
-- 8. SEED: 29 pgr_actions (catálogo perigo × consequência × ação)
-- ============================================================
INSERT INTO pgr_actions
  (subscale, danger_description, consequences, control_action, status)
VALUES
('Exigências Quantitativas',
 'Volume de tarefas excessivo para o tempo disponível, gerando acúmulo de demandas e horas extras frequentes.',
 'Fadiga crônica, erros operacionais, absenteísmo, síndrome de burnout e adoecimento musculoesquelético por esforço contínuo.',
 'Revisão do dimensionamento da equipe com análise de carga de trabalho; implantação de gestão de prioridades (metodologia Kanban ou similar); reuniões semanais de nivelamento de demandas entre líder e equipe.',
 'Pendente'),
('Ritmo de Trabalho',
 'Cadência imposta por metas, máquinas ou clientes sem possibilidade de pausa ou controle pelo trabalhador.',
 'Estresse agudo, distúrbios osteomusculares (LER/DORT), irritabilidade, queda de concentração e risco de acidentes.',
 'Implantação de pausas programadas a cada 50 minutos de trabalho contínuo; revisão de metas com participação dos trabalhadores; treinamento de líderes em gestão humanizada de resultados.',
 'Pendente'),
('Exigências Cognitivas',
 'Necessidade constante de atenção, memorização e tomada de decisão sob pressão, sem suporte técnico adequado.',
 'Esgotamento mental, lapsos de memória, dificuldade de concentração, ansiedade e erros com impacto na qualidade.',
 'Criação de checklists e procedimentos operacionais padrão (POPs) para reduzir carga cognitiva; treinamentos periódicos de atualização técnica; revisão da complexidade dos sistemas usados no dia a dia.',
 'Pendente'),
('Exigências Emocionais',
 'Exposição recorrente a situações de sofrimento alheio, conflitos com clientes ou necessidade de suprimir emoções no trabalho.',
 'Trauma vicário, desgaste emocional, insensibilização progressiva, depressão e síndrome de burnout.',
 'Programa de suporte psicológico com atendimento individual sigiloso; grupos de apoio entre pares facilitados por psicólogo; treinamento em regulação emocional e comunicação não violenta para toda a equipe.',
 'Pendente'),
('Influência no Trabalho',
 'Trabalhadores sem autonomia para decidir sobre método, ordem ou ritmo das próprias tarefas.',
 'Desmotivação, sensação de controle externo, redução do engajamento e maior suscetibilidade a estresse e adoecimento.',
 'Implantação de gestão participativa com espaços formais de escuta (reuniões mensais de equipe); delegação gradual de autonomia nas tarefas operacionais; revisão de processos que centralizam decisões desnecessariamente na liderança.',
 'Pendente'),
('Possibilidade de Desenvolvimento',
 'Ausência de oportunidades de aprendizado, crescimento ou uso de competências no trabalho cotidiano.',
 'Estagnação profissional percebida, desengajamento, rotatividade elevada e deterioração da saúde mental.',
 'Criação de plano de desenvolvimento individual (PDI) para todos os colaboradores; oferta de treinamentos internos e externos com horas remuneradas; mapeamento de trilhas de carreira formalizadas pelo RH.',
 'Pendente'),
('Previsibilidade',
 'Mudanças frequentes e não comunicadas em processos, metas, equipes ou condições de trabalho.',
 'Ansiedade antecipatória, insegurança, dificuldade de planejamento pessoal, impacto no sono e na vida familiar.',
 'Comunicação prévia e documentada de todas as mudanças organizacionais com pelo menos 2 semanas de antecedência; reuniões de alinhamento mensais com gestores; política de transparência sobre objetivos estratégicos da empresa.',
 'Pendente'),
('Transparência do Papel Laboral',
 'Ambiguidade sobre responsabilidades, metas e critérios de avaliação do desempenho do trabalhador.',
 'Conflito de papéis, sensação de injustiça, baixa performance e estresse por incerteza.',
 'Elaboração e entrega de descritivo de cargo atualizado para cada função; definição clara de metas individuais com critérios mensuráveis (OKRs ou similar); feedback formal de desempenho a cada 6 meses.',
 'Pendente'),
('Recompensas',
 'Percepção de que o esforço e os resultados entregues não são reconhecidos adequadamente em forma de salário, benefícios ou reconhecimento simbólico.',
 'Desmotivação, ressentimento, queda de engajamento, rotatividade voluntária e adoecimento mental por injustiça percebida.',
 'Revisão da política salarial com pesquisa de mercado; implantação de programa formal de reconhecimento meritocrático e transparente; criação de benefícios flexíveis alinhados às necessidades dos colaboradores.',
 'Pendente'),
('Conflitos Laborais',
 'Situações recorrentes em que os valores pessoais do trabalhador conflitam com o que é exigido pelo trabalho, como pressão para agir de forma antiética ou prejudicial a terceiros.',
 'Sofrimento moral, culpa, ansiedade, afastamentos e deterioração da identidade profissional.',
 'Criação de código de conduta claro com canal de denúncia sigiloso; treinamento de gestores para resolução de conflitos éticos; criação de comitê de ética acessível a todos os colaboradores.',
 'Pendente'),
('Apoio Social de Colegas',
 'Clima competitivo ou individualista que impede a cooperação e o suporte mútuo entre trabalhadores.',
 'Isolamento social, sobrecarga individual, conflitos interpessoais e piora do bem-estar no trabalho.',
 'Dinâmicas de integração de equipe facilitadas por psicólogo organizacional; revisão de políticas de remuneração que incentivem competição predatória; criação de rituais de reconhecimento coletivo como celebração de metas em grupo.',
 'Pendente'),
('Apoio Social de Superiores',
 'Lideranças que não oferecem suporte técnico ou emocional e são inacessíveis nos momentos de dificuldade.',
 'Sensação de abandono, aumento do estresse, decisões equivocadas por falta de orientação e adoecimento.',
 'Treinamento de líderes em saúde mental e gestão humanizada com mínimo de 16 horas; implantação de política de porta aberta com horários definidos; avaliação 360° da liderança com feedback estruturado anual.',
 'Pendente'),
('Comunidade Social no Trabalho',
 'Baixo senso de pertencimento e coesão entre os membros da equipe, com ausência de relações de confiança e colaboração.',
 'Isolamento, baixo engajamento coletivo, dificuldade de comunicação e maior vulnerabilidade a crises de equipe.',
 'Realização de eventos de integração periódicos presenciais ou remotos; criação de espaços informais de convivência no ambiente de trabalho; programas de mentoria e integração de novos colaboradores.',
 'Pendente'),
('Qualidade da Liderança',
 'Estilo de liderança autoritário, imprevisível ou omisso, gerando clima de medo ou desorientação na equipe.',
 'Medo de represálias, silenciamento de problemas, alta rotatividade e adoecimento psíquico coletivo.',
 'Programa de desenvolvimento de liderança com foco em gestão de pessoas e saúde mental; pesquisa de clima organizacional semestral com devolutiva para os líderes; acompanhamento individualizado de gestores com coaching executivo.',
 'Pendente'),
('Confiança Horizontal',
 'Ausência de confiança entre colegas do mesmo nível hierárquico, com episódios de sabotagem, fofoca ou omissão de informações.',
 'Clima organizacional tóxico, conflitos interpessoais frequentes, queda na colaboração e estresse relacional.',
 'Workshop de comunicação não violenta e resolução de conflitos para as equipes; mediação profissional em situações de conflito instalado; revisão de processos que criam dependência e concorrência desnecessária entre pares.',
 'Pendente'),
('Confiança Vertical',
 'Desconfiança dos trabalhadores em relação às intenções e decisões da gestão, com percepção de falta de transparência e honestidade.',
 'Resistência a mudanças, boicote velado, baixo comprometimento e deterioração do contrato psicológico.',
 'Política de comunicação organizacional transparente com prestação de contas regular; encontros periódicos entre alta liderança e equipes operacionais (town halls); ações concretas de cumprimento das promessas feitas pela gestão.',
 'Pendente'),
('Justiça e Respeito',
 'Percepção de tratamento desigual, favoritismo ou falta de reconhecimento no ambiente de trabalho.',
 'Desmotivação, ressentimento, conflitos internos, rotatividade e deterioração do clima organizacional.',
 'Revisão e comunicação clara dos critérios de promoção, bônus e reconhecimento; implantação de ouvidoria interna acessível; treinamento de gestores em tomada de decisão imparcial e comunicação respeitosa.',
 'Pendente'),
('Auto Eficácia',
 'Trabalhadores com baixa percepção de competência para lidar com os desafios do trabalho, frequentemente sobrecarregados ou sem treinamento adequado.',
 'Insegurança, procrastinação, medo de errar, baixa iniciativa e maior suscetibilidade ao estresse.',
 'Programa de capacitação técnica contínua alinhado às demandas do cargo; cultura de aprendizado com tolerância ao erro construtivo; feedback positivo e reconhecimento de progresso como práticas regulares da liderança.',
 'Pendente'),
('Significado do Trabalho',
 'Trabalhadores que não percebem propósito ou valor no que fazem, sentindo o trabalho como mecânico e sem sentido.',
 'Alienação, desmotivação profunda, absenteísmo e maior suscetibilidade a transtornos mentais.',
 'Comunicação do impacto do trabalho de cada área no resultado final da organização; reconhecimento público de contribuições individuais e coletivas; envolvimento dos colaboradores em decisões que afetam diretamente seu trabalho.',
 'Pendente'),
('Compromisso com o Local de Trabalho',
 'Baixo vínculo afetivo e de identificação do trabalhador com a organização, percepção de que a empresa não investe nas pessoas.',
 'Alta rotatividade voluntária, desengajamento, presenteísmo e dificuldade de retenção de talentos.',
 'Implantação de programa de employee experience com escuta ativa dos colaboradores; revisão de benefícios e condições de trabalho com base em pesquisa interna; programa de integração robusto para novos colaboradores.',
 'Pendente'),
('Satisfação no Trabalho',
 'Baixa satisfação geral com as condições, relações e sentido do trabalho realizado.',
 'Rotatividade elevada, baixo desempenho, absenteísmo e maior vulnerabilidade a adoecimento mental.',
 'Pesquisa de clima semestral com plano de ação obrigatório e prazo definido; reuniões individuais de check-in entre gestor e colaborador mensalmente; revisão de benefícios e condições de trabalho com base nos resultados.',
 'Pendente'),
('Insegurança Laboral',
 'Percepção de ameaça real ou imaginária de perda do emprego, rebaixamento ou mudanças indesejadas nas condições de trabalho.',
 'Ansiedade crônica, comportamento de autopreservação, queda de engajamento e adoecimento psíquico.',
 'Comunicação transparente sobre a situação financeira e planos da empresa; criação de plano de carreira com critérios claros de permanência e progressão; programa de requalificação profissional para casos de reestruturação.',
 'Pendente'),
('Saúde Geral',
 'Percepção negativa do próprio estado de saúde associada às condições de trabalho como esforço físico, turnos noturnos, ambiente insalubre ou estresse crônico.',
 'Absenteísmo por doença, afastamentos previdenciários, queda de produtividade e aumento do custo assistencial.',
 'Programa de saúde ocupacional com exames periódicos e acompanhamento médico; oferta de atividades de promoção de saúde como ginástica laboral, orientação nutricional e suporte em saúde mental; revisão das condições ambientais do trabalho quanto a ergonomia, ruído e temperatura.',
 'Pendente'),
('Conflito Trabalho/Família',
 'Jornadas extensas, imprevisibilidade de horários e cultura de disponibilidade permanente invadindo a vida pessoal e familiar.',
 'Conflitos familiares, culpa, isolamento social, adoecimento e rotatividade elevada.',
 'Implantação de política de desconexão digital com horário definido; flexibilização de horários para responsáveis por dependentes; revisão da cultura de horas extras como indicador de comprometimento.',
 'Pendente'),
('Problemas para Dormir',
 'Trabalho em turnos, sobreaviso fora do horário ou alto nível de preocupação com o trabalho impedindo o descanso adequado.',
 'Privação de sono, queda cognitiva, irritabilidade, maior risco de acidentes e desenvolvimento de doenças crônicas.',
 'Revisão da política de sobreaviso e contato fora do expediente; campanhas internas de higiene do sono; avaliação da viabilidade de redução de trabalho noturno ou rotação de turnos com descanso mínimo de 11 horas entre jornadas.',
 'Pendente'),
('Burnout',
 'Exposição prolongada a demandas excessivas sem recuperação adequada, levando ao esgotamento físico e mental do trabalhador.',
 'Afastamentos prolongados por transtornos mentais (CID F43), queda acentuada de produtividade e risco de automutilação.',
 'Implantação de programa de bem-estar com acesso facilitado a psicólogo; revisão da carga de trabalho das equipes com maior incidência; treinamento de líderes para identificação precoce de sinais de burnout na equipe.',
 'Pendente'),
('Stress',
 'Desequilíbrio crônico entre as exigências do trabalho e a capacidade de resposta do trabalhador, sem períodos adequados de recuperação.',
 'Hipertensão, doenças cardiovasculares, distúrbios do sono, ansiedade generalizada e imunossupressão.',
 'Oferta de sessões de mindfulness ou meditação guiada semanais no ambiente de trabalho; implantação de política de desconexão digital fora do horário de trabalho; disponibilização de apoio psicológico via plano de saúde ou serviço próprio da empresa.',
 'Pendente'),
('Sintomas Depressivos',
 'Ambiente de trabalho com fatores de risco acumulados como baixo controle, baixo suporte e alta demanda, associados a tristeza persistente e perda de interesse.',
 'Afastamentos por transtornos depressivos (CID F32/F33), risco de suicídio e impacto severo nas relações familiares e sociais.',
 'Rastreamento periódico de saúde mental com instrumento validado como o PHQ-9; garantia de acesso a tratamento psicológico e psiquiátrico pelo plano de saúde; treinamento de gestores em identificação de sinais de alerta e encaminhamento adequado.',
 'Pendente'),
('Comportamentos Ofensivos',
 'Ocorrência de assédio moral, assédio sexual, discriminação ou violência verbal no ambiente de trabalho.',
 'Trauma psicológico, afastamentos, processos trabalhistas, deterioração do clima organizacional e adoecimento coletivo.',
 'Implementação de canal de denúncia sigiloso com comitê independente de apuração; política de tolerância zero documentada e amplamente divulgada; treinamento obrigatório anual sobre assédio e discriminação para todos os níveis hierárquicos.',
 'Pendente')
ON CONFLICT (subscale) DO UPDATE SET
  danger_description = EXCLUDED.danger_description,
  consequences       = EXCLUDED.consequences,
  control_action     = EXCLUDED.control_action;
