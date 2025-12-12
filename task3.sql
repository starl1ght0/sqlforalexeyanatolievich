-- Удаляем старую функцию если есть
DROP FUNCTION IF EXISTS show_transferred_points();

-- 1) Функция, которая показывает "чистые" передаваемые очки между пирами
-- Это как считать, кто кому реально помог, если они проверяют друг друга

CREATE OR REPLACE FUNCTION show_transferred_points()
RETURNS TABLE (
    checker varchar,   -- Кто проверял
    checked varchar,   -- Кого проверяли
    points integer     -- Чистые очки (после вычета взаимных проверок)
) AS $$
BEGIN
    RETURN QUERY
    -- Находим пары пиров, которые проверяли друг друга
    WITH mutual_pairs AS (
        -- Пиры, которые проверяли друг друга
        SELECT 
            tp1.checkingpeer AS peer1,
            tp1.checkedpeer AS peer2,
            tp1.pointsamount AS points1to2,
            COALESCE(tp2.pointsamount, 0) AS points2to1
        FROM transferredpoints tp1
        -- Ищем взаимные проверки
        LEFT JOIN transferredpoints tp2 
            ON tp1.checkingpeer = tp2.checkedpeer 
            AND tp1.checkedpeer = tp2.checkingpeer
        WHERE tp2.checkingpeer IS NOT NULL
           OR tp1.pointsamount > 0
    ),
    
    -- Вычисляем чистые очки (разницу между взаимными проверками)
    net_points AS (
        SELECT 
            peer1 AS checker,
            peer2 AS checked,
            points1to2 - points2to1 AS net
        FROM mutual_pairs
        WHERE points1to2 > points2to1  -- Только если разница положительная
        
        UNION
        
        -- Показываем обычные проверки (без взаимности)
        SELECT 
            checkingpeer,
            checkedpeer,
            pointsamount
        FROM transferredpoints tp
        WHERE NOT EXISTS (
            SELECT 1 FROM transferredpoints tp2
            WHERE tp.checkingpeer = tp2.checkedpeer
              AND tp.checkedpeer = tp2.checkingpeer
        )
    )
    
    -- Возвращаем результат отсортированным
    SELECT checker, checked, net::integer
    FROM net_points
    WHERE net > 0  -- Показываем только положительные чистые очки
    ORDER BY checker, checked;
END;
$$ LANGUAGE plpgsql;

-- Тестируем: SELECT * FROM show_transferred_points();


-- 2) Функция показывает, кто какие задания успешно сдал и сколько XP получил
-- Как таблица лидеров в игре

CREATE OR REPLACE FUNCTION show_successful_checks()
RETURNS TABLE (
    peer_name varchar,   -- Имя пира
    task_name varchar,   -- Название задания
    earned_xp integer    -- Заработанные XP
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        checks.peer,
        checks.task,
        xp.xpamount
    FROM checks
    -- Присоединяем таблицу P2P чтобы узнать результат проверки
    JOIN p2p ON checks.id = p2p."Check"
    -- Присоединяем таблицу XP чтобы узнать сколько очков получили
    JOIN xp ON checks.id = xp."Check"
    WHERE p2p.state = 'Success'  -- Только успешные проверки
    ORDER BY checks.peer, checks.task;
END;
$$ LANGUAGE plpgsql;

-- Тестируем: SELECT * FROM show_successful_checks();


-- 3) Функция ищет пиров, которые не выходили из кампуса весь день
-- Как искали бы тех, кто застрял в библиотеке

CREATE OR REPLACE FUNCTION find_all_day_students(check_date date)
RETURNS TABLE (peer_name varchar) AS $$
BEGIN
    RETURN QUERY
    -- Ищем пиров, у которых за день была только одна запись о выходе (или вообще не было)
    SELECT DISTINCT timetracking.peer
    FROM timetracking
    WHERE date = check_date
    GROUP BY timetracking.peer
    -- Если пир вошел и не вышел, или вошел только один раз
    HAVING COUNT(CASE WHEN state = 2 THEN 1 END) = 0  -- Нет записей о выходе
        OR COUNT(*) = 1;  -- Только одна запись за день (только вход)
END;
$$ LANGUAGE plpgsql;

-- Пример: кто не выходил 2 апреля 2023
-- SELECT * FROM find_all_day_students('2023-04-02');


-- 4) Процедура считает баланс очков у каждого пира
-- Как считать, кто больше помогал, а кому больше помогали

CREATE OR REPLACE PROCEDURE calculate_peer_points(IN result_cursor refcursor)
AS $$
BEGIN
    OPEN result_cursor FOR
    -- Считаем сколько очков пир получил (когда его проверяли другие)
    WITH points_received AS (
        SELECT 
            checkingpeer AS peer,
            SUM(pointsamount) AS points
        FROM transferredpoints
        GROUP BY checkingpeer
    ),
    
    -- Считаем сколько очков пир отдал (когда проверял других)
    points_given AS (
        SELECT 
            checkedpeer AS peer,
            -SUM(pointsamount) AS points  -- Минус, потому что отдал
        FROM transferredpoints
        GROUP BY checkedpeer
    ),
    
    -- Объединяем полученные и отданные очки
    all_points AS (
        SELECT * FROM points_received
        UNION ALL
        SELECT * FROM points_given
    )
    
    -- Итоговый баланс для каждого пира
    SELECT 
        peer,
        COALESCE(SUM(points), 0) AS total_points
    FROM all_points
    GROUP BY peer
    ORDER BY total_points DESC;  -- Сначала те, у кого больше очков
END;
$$ LANGUAGE plpgsql;

-- Использование:
-- BEGIN;
-- CALL calculate_peer_points('my_cursor');
-- FETCH ALL FROM my_cursor;
-- END;


-- 5) Та же функция, но с использованием первой функции для чистых очков

CREATE OR REPLACE PROCEDURE calculate_net_peer_points(IN result_cursor refcursor)
AS $$
BEGIN
    OPEN result_cursor FOR
    -- Используем функцию из задания 1 для чистых очков
    WITH net_points AS (
        SELECT * FROM show_transferred_points()
    ),
    
    -- Считаем чистые полученные очки
    received AS (
        SELECT 
            checker AS peer,
            SUM(points) AS points
        FROM net_points
        GROUP BY checker
    ),
    
    -- Считаем чистые отданные очки (отрицательные)
    given AS (
        SELECT 
            checked AS peer,
            -SUM(points) AS points
        FROM net_points
        GROUP BY checked
    ),
    
    -- Объединяем
    all_net_points AS (
        SELECT * FROM received
        UNION ALL
        SELECT * FROM given
    )
    
    -- Итоговый чистый баланс
    SELECT 
        peer,
        COALESCE(SUM(points), 0) AS net_total
    FROM all_net_points
    GROUP BY peer
    ORDER BY net_total DESC;
END;
$$ LANGUAGE plpgsql;


-- 6) Процедура находит самое популярное задание для проверки в каждый день
-- Какое задание чаще всего сдавали в каждый день

CREATE OR REPLACE PROCEDURE find_daily_popular_tasks(IN result_cursor refcursor)
AS $$
BEGIN
    OPEN result_cursor FOR
    WITH daily_counts AS (
        -- Считаем сколько раз каждое задание сдавали в каждый день
        SELECT 
            date,
            task,
            COUNT(*) AS check_count
        FROM checks
        GROUP BY date, task
    ),
    
    -- Находим максимальное количество сдач для каждого дня
    max_daily AS (
        SELECT 
            date,
            MAX(check_count) AS max_count
        FROM daily_counts
        GROUP BY date
    )
    
    -- Выбираем задания, которые сдавали максимальное количество раз в день
    SELECT 
        dc.date,
        dc.task
    FROM daily_counts dc
    JOIN max_daily md ON dc.date = md.date AND dc.check_count = md.max_count
    ORDER BY dc.date;
END;
$$ LANGUAGE plpgsql;


-- 7) Процедура ищет пиров, которые прошли весь блок заданий
-- Например, все задания блока "C" или "SQL"

CREATE OR REPLACE PROCEDURE find_block_completers(
    IN result_cursor refcursor,
    IN block_prefix varchar
)
AS $$
BEGIN
    OPEN result_cursor FOR
    -- Находим все задания в блоке (например, все "C%")
    WITH block_tasks AS (
        SELECT title
        FROM tasks
        WHERE title LIKE block_prefix || '%'
    ),
    
    -- Находим пиров, которые успешно сдали все задания блока
    completers AS (
        SELECT 
            c.peer,
            MAX(c.date) AS completion_date  -- Дата последнего сданного задания
        FROM checks c
        JOIN xp ON c.id = xp."Check"  -- Проверяем что задание сдано успешно
        WHERE c.task IN (SELECT title FROM block_tasks)
        GROUP BY c.peer
        -- Проверяем, что пир сдал ВСЕ задания блока
        HAVING COUNT(DISTINCT c.task) = (SELECT COUNT(*) FROM block_tasks)
    )
    
    SELECT 
        peer,
        completion_date
    FROM completers
    ORDER BY completion_date;
END;
$$ LANGUAGE plpgsql;

-- Пример: кто прошел весь блок C заданий
-- CALL find_block_completers('my_cursor', 'C');


-- 8) Процедура рекомендует, к кому обращаться за проверкой
-- Смотрит рекомендации друзей

CREATE OR REPLACE PROCEDURE get_recommendations(IN result_cursor refcursor)
AS $$
BEGIN
    OPEN result_cursor FOR
    WITH friend_recommendations AS (
        -- Собираем все рекомендации друзей
        SELECT 
            f.peer1 AS peer,
            r.recommendedpeer AS recommended
        FROM friends f
        JOIN recommendations r ON f.peer2 = r.peer
        WHERE f.peer1 != r.recommendedpeer  -- Не рекомендовать себя
    ),
    
    -- Считаем, кого чаще всего рекомендуют каждому пиру
    recommendation_counts AS (
        SELECT 
            peer,
            recommended,
            COUNT(*) AS recommendation_count
        FROM friend_recommendations
        GROUP BY peer, recommended
    ),
    
    -- Для каждого пира находим самого часто рекомендуемого
    top_recommendations AS (
        SELECT 
            peer,
            recommended,
            recommendation_count,
            ROW_NUMBER() OVER (PARTITION BY peer ORDER BY recommendation_count DESC) AS rank
        FROM recommendation_counts
    )
    
    SELECT 
        peer,
        recommended
    FROM top_recommendations
    WHERE rank = 1  -- Только самый частый рекомендатель
    ORDER BY peer;
END;
$$ LANGUAGE plpgsql;


-- 9) Процедура анализирует, кто начал какие блоки заданий
-- Показывает статистику по блокам

CREATE OR REPLACE PROCEDURE analyze_block_start(
    IN result_cursor refcursor,
    IN block1_name varchar,
    IN block2_name varchar
)
AS $$
DECLARE
    total_peers integer;
BEGIN
    -- Считаем общее количество пиров
    SELECT COUNT(*) INTO total_peers FROM peers;
    IF total_peers = 0 THEN total_peers := 1; END IF;  -- Чтобы не делить на 0
    
    OPEN result_cursor FOR
    WITH started_block1 AS (
        -- Кто начал первый блок
        SELECT DISTINCT peer
        FROM checks
        WHERE task LIKE block1_name || '%'
    ),
    
    started_block2 AS (
        -- Кто начал второй блок
        SELECT DISTINCT peer
        FROM checks
        WHERE task LIKE block2_name || '%'
    ),
    
    started_both AS (
        -- Кто начал оба блока
        SELECT peer FROM started_block1
        INTERSECT
        SELECT peer FROM started_block2
    ),
    
    started_none AS (
        -- Кто не начал ни один блок
        SELECT nickname AS peer
        FROM peers
        WHERE nickname NOT IN (SELECT peer FROM started_block1)
          AND nickname NOT IN (SELECT peer FROM started_block2)
    )
    
    -- Вычисляем проценты
    SELECT 
        -- Процент начавших первый блок
        ROUND((SELECT COUNT(*)::numeric FROM started_block1) / total_peers * 100, 2) AS started_block1_percent,
        -- Процент начавших второй блок
        ROUND((SELECT COUNT(*)::numeric FROM started_block2) / total_peers * 100, 2) AS started_block2_percent,
        -- Процент начавших оба блока
        ROUND((SELECT COUNT(*)::numeric FROM started_both) / total_peers * 100, 2) AS started_both_percent,
        -- Процент не начавших ни один
        ROUND((SELECT COUNT(*)::numeric FROM started_none) / total_peers * 100, 2) AS started_none_percent;
END;
$$ LANGUAGE plpgsql;


-- 10) Процедура смотрит, как пиры сдают проверки в свой день рождения

CREATE OR REPLACE PROCEDURE analyze_birthday_checks(IN result_cursor refcursor)
AS $$
BEGIN
    OPEN result_cursor FOR
    WITH birthday_checks AS (
        -- Находим проверки, которые были в день рождения пира
        SELECT 
            p.nickname,
            c.id AS check_id,
            -- Сравниваем только месяц и день (без года)
            EXTRACT(MONTH FROM p.birthday) AS birth_month,
            EXTRACT(DAY FROM p.birthday) AS birth_day,
            EXTRACT(MONTH FROM c.date) AS check_month,
            EXTRACT(DAY FROM c.date) AS check_day
        FROM peers p
        JOIN checks c ON p.nickname = c.peer
    ),
    
    birthday_results AS (
        -- Смотрим результаты этих проверок
        SELECT 
            bc.nickname,
            p2p.state AS result
        FROM birthday_checks bc
        JOIN p2p ON bc.check_id = p2p."Check"
        WHERE bc.birth_month = bc.check_month
          AND bc.birth_day = bc.check_day
          AND p2p.state IN ('Success', 'Failure')
    ),
    
    counts AS (
        -- Считаем успешные и неуспешные проверки
        SELECT 
            COUNT(CASE WHEN result = 'Success' THEN 1 END) AS success_count,
            COUNT(CASE WHEN result = 'Failure' THEN 1 END) AS failure_count,
            COUNT(*) AS total_count
        FROM birthday_results
    )
    
    -- Вычисляем проценты
    SELECT 
        CASE 
            WHEN total_count = 0 THEN 0 
            ELSE ROUND(success_count::numeric / total_count * 100, 2) 
        END AS success_percent,
        
        CASE 
            WHEN total_count = 0 THEN 0 
            ELSE ROUND(failure_count::numeric / total_count * 100, 2) 
        END AS failure_percent
    FROM counts;
END;
$$ LANGUAGE plpgsql;


-- 11) Процедура ищет пиров, которые сдали задания 1 и 2, но не задание 3

CREATE OR REPLACE PROCEDURE find_peers_with_pattern(
    IN result_cursor refcursor,
    IN task1_name varchar,
    IN task2_name varchar,
    IN task3_name varchar
)
AS $$
BEGIN
    OPEN result_cursor FOR
    -- Пиры, успешно сдавшие первое задание
    WITH completed_task1 AS (
        SELECT DISTINCT c.peer
        FROM checks c
        JOIN xp ON c.id = xp."Check"
        WHERE c.task = task1_name
    ),
    
    -- Пиры, успешно сдавшие второе задание
    completed_task2 AS (
        SELECT DISTINCT c.peer
        FROM checks c
        JOIN xp ON c.id = xp."Check"
        WHERE c.task = task2_name
    ),
    
    -- Пиры, которые НЕ сдали третье задание
    not_completed_task3 AS (
        -- Все пиры кроме тех, кто сдал задание 3
        SELECT nickname AS peer
        FROM peers
        WHERE nickname NOT IN (
            SELECT DISTINCT c.peer
            FROM checks c
            JOIN xp ON c.id = xp."Check"
            WHERE c.task = task3_name
        )
    )
    
    -- Ищем пересечение: сдали 1 и 2, но не сдали 3
    SELECT peer
    FROM completed_task1
    INTERSECT
    SELECT peer
    FROM completed_task2
    INTERSECT
    SELECT peer
    FROM not_completed_task3
    ORDER BY peer;
END;
$$ LANGUAGE plpgsql;


-- 12) Функция считает, сколько родительских заданий у каждого задания
-- Использует рекурсию - как считать предков в генеалогическом древе

CREATE OR REPLACE FUNCTION count_parent_tasks()
RETURNS TABLE (
    task_name varchar,
    parent_count integer
) AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE task_tree AS (
        -- Базовый случай: задания без родителей (корни дерева)
        SELECT 
            title,
            parenttask,
            0 AS level  -- Уровень вложенности
        FROM tasks
        WHERE parenttask IS NULL
        
        UNION ALL
        
        -- Рекурсивный шаг: идем от родителей к детям
        SELECT 
            t.title,
            t.parenttask,
            tt.level + 1  -- Увеличиваем уровень на 1
        FROM tasks t
        JOIN task_tree tt ON t.parenttask = tt.title
    )
    
    SELECT 
        title,
        MAX(level) AS depth
    FROM task_tree
    GROUP BY title
    ORDER BY title;
END;
$$ LANGUAGE plpgsql;

-- Тестируем: SELECT * FROM count_parent_tasks();


-- 13) Процедура ищет "счастливые" дни - когда много проверок подряд успешны

CREATE OR REPLACE PROCEDURE find_lucky_days(
    IN result_cursor refcursor,
    IN min_streak integer
)
AS $$
BEGIN
    OPEN result_cursor FOR
    WITH successful_checks AS (
        -- Находим успешные проверки с высоким XP (>80% от максимума)
        SELECT 
            c.id,
            c.date,
            p2p.time,
            ROW_NUMBER() OVER (PARTITION BY c.date ORDER BY p2p.time) AS check_num
        FROM checks c
        JOIN p2p ON c.id = p2p."Check"
        JOIN xp ON c.id = xp."Check"
        JOIN tasks ON c.task = tasks.title
        WHERE p2p.state = 'Success'
          AND xp.xpamount >= tasks.maxxp * 0.8
    ),
    
    -- Ищем последовательности успешных проверок
    check_streaks AS (
        SELECT 
            date,
            check_num,
            check_num - ROW_NUMBER() OVER (PARTITION BY date ORDER BY check_num) AS streak_group
        FROM successful_checks
    ),
    
    -- Считаем длину каждой последовательности
    streak_lengths AS (
        SELECT 
            date,
            streak_group,
            COUNT(*) AS streak_length
        FROM check_streaks
        GROUP BY date, streak_group
    )
    
    -- Находим дни с последовательностями нужной длины
    SELECT DISTINCT date
    FROM streak_lengths
    WHERE streak_length >= min_streak
    ORDER BY date;
END;
$$ LANGUAGE plpgsql;


-- 14) Функция находит пира с максимальным количеством XP
-- Как найти лидера таблицы

CREATE OR REPLACE FUNCTION find_xp_leader()
RETURNS TABLE (
    peer_name varchar,
    total_xp bigint
) AS $$
BEGIN
    RETURN QUERY
    WITH peer_xp_totals AS (
        -- Суммируем все XP каждого пира
        SELECT 
            c.peer,
            SUM(x.xpamount) AS total_xp
        FROM checks c
        JOIN xp x ON c.id = x."Check"
        GROUP BY c.peer
    )
    
    -- Находим максимальное значение и возвращаем пира (или пиров) с ним
    SELECT 
        peer,
        total_xp
    FROM peer_xp_totals
    WHERE total_xp = (SELECT MAX(total_xp) FROM peer_xp_totals)
    ORDER BY peer;
END;
$$ LANGUAGE plpgsql;

-- Тестируем: SELECT * FROM find_xp_leader();


-- 15) Процедура ищет пиров, которые часто приходят рано

CREATE OR REPLACE PROCEDURE find_early_birds(
    IN result_cursor refcursor,
    IN early_time time,
    IN min_entries integer
)
AS $$
BEGIN
    OPEN result_cursor FOR
    -- Считаем сколько раз каждый пир приходил рано
    WITH early_entries AS (
        SELECT 
            peer,
            COUNT(DISTINCT date) AS early_days
        FROM timetracking
        WHERE state = 1  -- Вход
          AND time < early_time
        GROUP BY peer
    )
    
    SELECT 
        peer,
        early_days
    FROM early_entries
    WHERE early_days >= min_entries
    ORDER BY early_days DESC, peer;
END;
$$ LANGUAGE plpgsql;


-- 16) Процедура ищет пиров, которые часто выходят из кампуса

CREATE OR REPLACE PROCEDURE find_frequent_exiters(
    IN result_cursor refcursor,
    IN days_back integer,
    IN min_exits integer
)
AS $$
DECLARE
    start_date date;
BEGIN
    -- Вычисляем дату начала периода
    start_date := CURRENT_DATE - days_back;
    
    OPEN result_cursor FOR
    -- Считаем выходы за последние N дней
    WITH recent_exits AS (
        SELECT 
            peer,
            COUNT(DISTINCT date) AS exit_days
        FROM timetracking
        WHERE state = 2  -- Выход
          AND date >= start_date
        GROUP BY peer
    )
    
    SELECT 
        peer,
        exit_days
    FROM recent_exits
    WHERE exit_days >= min_exits
    ORDER BY exit_days DESC, peer;
END;
$$ LANGUAGE plpgsql;


-- 17) Функция считает процент ранних приходов по месяцам
-- Смотрит, приходят ли пиры рано в месяц своего рождения

CREATE OR REPLACE FUNCTION calculate_early_entry_stats()
RETURNS TABLE (
    month_name varchar,
    early_percent numeric
) AS $$
BEGIN
    RETURN QUERY
    WITH birthday_months AS (
        -- Собираем все месяцы (январь-декабрь)
        SELECT 
            generate_series(1, 12) AS month_num,
            to_char(make_date(2000, generate_series(1, 12), 1), 'Month') AS month_name
    ),
    
    early_birthday_entries AS (
        -- Считаем ранние входы в месяц рождения
        SELECT 
            EXTRACT(MONTH FROM p.birthday) AS birth_month,
            COUNT(*) AS early_count
        FROM timetracking tt
        JOIN peers p ON tt.peer = p.nickname
        WHERE tt.state = 1  -- Вход
          AND EXTRACT(MONTH FROM tt.date) = EXTRACT(MONTH FROM p.birthday)
          AND tt.time < '12:00:00'  -- До полудня
        GROUP BY EXTRACT(MONTH FROM p.birthday)
    ),
    
    total_birthday_entries AS (
        -- Считаем все входы в месяц рождения
        SELECT 
            EXTRACT(MONTH FROM p.birthday) AS birth_month,
            COUNT(*) AS total_count
        FROM timetracking tt
        JOIN peers p ON tt.peer = p.nickname
        WHERE tt.state = 1  -- Вход
          AND EXTRACT(MONTH FROM tt.date) = EXTRACT(MONTH FROM p.birthday)
        GROUP BY EXTRACT(MONTH FROM p.birthday)
    )
    
    -- Вычисляем проценты для каждого месяца
    SELECT 
        TRIM(bm.month_name),
        COALESCE(
            ROUND(
                COALESCE(ebe.early_count, 0)::numeric / 
                NULLIF(tbe.total_count, 0) * 100, 
            1), 
            0
        ) AS early_percentage
    FROM birthday_months bm
    LEFT JOIN early_birthday_entries ebe ON bm.month_num = ebe.birth_month
    LEFT JOIN total_birthday_entries tbe ON bm.month_num = tbe.birth_month
    ORDER BY bm.month_num;
END;
$$ LANGUAGE plpgsql;

-- Тестируем: SELECT * FROM calculate_early_entry_stats();


-- Удобная функция для тестирования всех процедур
CREATE OR REPLACE PROCEDURE test_all_functions()
AS $$
DECLARE
    test_cursor refcursor;
    rec record;
BEGIN
    RAISE NOTICE '=== Тестируем все функции и процедуры ===';
    
    -- 1. Показываем передаваемые очки
    RAISE NOTICE '1. Передаваемые очки:';
    FOR rec IN SELECT * FROM show_transferred_points() LIMIT 5
    LOOP
        RAISE NOTICE '   % -> %: % очков', rec.checker, rec.checked, rec.points;
    END LOOP;
    
    -- 2. Успешные проверки
    RAISE NOTICE '2. Успешные проверки (первые 5):';
    FOR rec IN SELECT * FROM show_successful_checks() LIMIT 5
    LOOP
        RAISE NOTICE '   % сдал %: % XP', rec.peer_name, rec.task_name, rec.earned_xp;
    END LOOP;
    
    -- 14. Лидер по XP
    RAISE NOTICE '14. Лидер по XP:';
    FOR rec IN SELECT * FROM find_xp_leader()
    LOOP
        RAISE NOTICE '   %: % XP', rec.peer_name, rec.total_xp;
    END LOOP;
    
    -- 17. Статистика ранних приходов
    RAISE NOTICE '17. Ранние приходы в месяц рождения:';
    FOR rec IN SELECT * FROM calculate_early_entry_stats()
    LOOP
        RAISE NOTICE '   %: %%%', rec.month_name, rec.early_percent;
    END LOOP;
    
    RAISE NOTICE '=== Тестирование завершено ===';
END;
$$ LANGUAGE plpgsql;

-- Запускаем тесты
-- CALL test_all_functions();
