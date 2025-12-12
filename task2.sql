CREATE OR REPLACE PROCEDURE add_peer_review(
    checked_peer varchar,    -- Кого проверяют (например, 'peer1')
    checking_peer varchar,   -- Кто проверяет (например, 'peer2')
    task_name text,          -- Какое задание проверяем (например, 'C5_s21_decimal')
    p2p_status check_status, -- Статус: 'Start', 'Success' или 'Failure'
    p2p_time TIME            -- Время проверки (например, '10:11:00')
) AS $$
DECLARE
    check_id BIGINT;         -- Переменная для хранения ID проверки
BEGIN
    -- Если статус 'Start' - это начало новой проверки
    IF (p2p_status = 'Start') THEN
        -- Проверяем, нет ли уже незавершенной проверки между этими пирами
        IF NOT EXISTS (
            SELECT 1 FROM p2p
            JOIN checks ON p2p."Check" = checks.id
            WHERE p2p.checkingpeer = checking_peer
                AND checks.peer = checked_peer
                AND checks.task = task_name
                AND p2p.state = 'Start'  -- Ищем незавершенные проверки
        ) THEN
            -- Сначала добавляем запись в таблицу Checks
            INSERT INTO checks (peer, task, date)
            VALUES (checked_peer, task_name, CURRENT_DATE)
            RETURNING id INTO check_id;  -- Запоминаем ID новой проверки
            
            -- Теперь добавляем запись в P2P
            INSERT INTO p2p ("Check", checkingpeer, state, time)
            VALUES (check_id, checking_peer, p2p_status, p2p_time);
            
            RAISE NOTICE 'Новая проверка создана! ID: %', check_id;
        ELSE
            -- Если уже есть незавершенная проверка, выводим ошибку
            RAISE EXCEPTION 'Ошибка: У этих пиров уже есть незавершенная проверка!';
        END IF;
    ELSE
        -- Если статус не 'Start', значит это завершение существующей проверки
        -- Находим ID последней незавершенной проверки
        SELECT checks.id INTO check_id
        FROM p2p
        JOIN checks ON p2p."Check" = checks.id
        WHERE checks.peer = checked_peer
            AND checks.task = task_name
            AND p2p.checkingpeer = checking_peer
            AND p2p.state = 'Start'  -- Ищем начатую проверку
        ORDER BY p2p.time DESC
        LIMIT 1;
        
        IF check_id IS NULL THEN
            RAISE EXCEPTION 'Ошибка: Не найдена начатая проверка для завершения!';
        END IF;
        
        -- Добавляем запись о завершении проверки
        INSERT INTO p2p ("Check", checkingpeer, state, time)
        VALUES (check_id, checking_peer, p2p_status, p2p_time);
        
        RAISE NOTICE 'Проверка % завершена со статусом: %', check_id, p2p_status;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Тестируем процедуру:
-- 1. Начинаем новую проверку
-- CALL add_peer_review('peer1', 'peer2', 'C5_s21_decimal', 'Start', '10:11:00');

-- 2. Завершаем проверку успешно
-- CALL add_peer_review('peer1', 'peer2', 'C5_s21_decimal', 'Success', '11:00:00');

-- 3. Попробуем начать новую проверку, когда старая не завершена (должна быть ошибка)
-- CALL add_peer_review('peer1', 'peer2', 'C5_s21_decimal', 'Start', '12:00:00');


-- 2) Процедура для добавления автоматической проверки (Verter)
-- Это как автотесты после того, как пир проверил работу

CREATE OR REPLACE PROCEDURE add_verter_review(
    checked_peer varchar,      -- Кого проверяем
    task_name text,            -- Какое задание
    verter_status check_status, -- Статус автотестов
    verter_time time           -- Время проверки
) AS $$
DECLARE
    last_success_check BIGINT;  -- ID последней успешной P2P проверки
BEGIN
    -- Находим последнюю успешную P2P проверку для этого пира и задания
    SELECT checks.id INTO last_success_check
    FROM p2p
    JOIN checks ON p2p."Check" = checks.id
    WHERE checks.peer = checked_peer
        AND checks.task = task_name
        AND p2p.state = 'Success'  -- Только успешные P2P проверки
    ORDER BY p2p.time DESC
    LIMIT 1;
    
    -- Если не нашли успешную P2P проверку
    IF last_success_check IS NULL THEN
        RAISE EXCEPTION 'Ошибка: Нет успешной P2P проверки для задания % у пира %', 
                        task_name, checked_peer;
    END IF;
    
    -- Если статус 'Start' - начинаем автотесты
    IF (verter_status = 'Start') THEN
        -- Проверяем, не начаты ли уже автотесты для этой проверки
        IF NOT EXISTS (
            SELECT 1 FROM verter
            WHERE "Check" = last_success_check
                AND state = 'Start'
        ) THEN
            INSERT INTO verter ("Check", state, time)
            VALUES (last_success_check, 'Start', verter_time);
            RAISE NOTICE 'Автотесты начаты для проверки %', last_success_check;
        ELSE
            RAISE EXCEPTION 'Автотесты уже начаты для этой проверки!';
        END IF;
    ELSE
        -- Завершаем автотесты (Success или Failure)
        -- Находим начатые автотесты для завершения
        IF EXISTS (
            SELECT 1 FROM verter
            WHERE "Check" = last_success_check
                AND state = 'Start'
        ) THEN
            INSERT INTO verter ("Check", state, time)
            VALUES (last_success_check, verter_status, verter_time);
            RAISE NOTICE 'Автотесты завершены со статусом: %', verter_status;
        ELSE
            RAISE EXCEPTION 'Не найдены начатые автотесты для завершения!';
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Тестируем:
-- 1. Начинаем автотесты после успешной P2P проверки
-- CALL add_verter_review('peer2', 'C4_s21_math', 'Start', '10:11:00');

-- 2. Завершаем автотесты успешно
-- CALL add_verter_review('peer2', 'C4_s21_math', 'Success', '10:12:00');


-- 3) Триггер для автоматического обновления очков помощи
-- Триггер - это как автоматическая реакция на событие (вставка, удаление, обновление)

-- Сначала создаем функцию, которая будет выполняться триггером
CREATE OR REPLACE FUNCTION update_transferred_points()
RETURNS TRIGGER AS $$
DECLARE
    checked_peer_name varchar;  -- Имя проверяемого пира
BEGIN
    -- Получаем имя проверяемого пира из таблицы Checks
    SELECT peer INTO checked_peer_name
    FROM checks
    WHERE id = NEW."Check";
    
    -- Если это начало новой проверки
    IF (NEW.state = 'Start') THEN
        -- Проверяем, существует ли уже запись для этой пары пиров
        IF EXISTS (
            SELECT 1 FROM transferredpoints
            WHERE checkingpeer = NEW.checkingpeer
                AND checkedpeer = checked_peer_name
        ) THEN
            -- Если запись есть, увеличиваем счетчик на 1
            UPDATE transferredpoints
            SET pointsamount = pointsamount + 1
            WHERE checkingpeer = NEW.checkingpeer
                AND checkedpeer = checked_peer_name;
            
            RAISE NOTICE 'Увеличены очки помощи для пары % -> %', 
                         NEW.checkingpeer, checked_peer_name;
        ELSE
            -- Если записи нет, создаем новую
            INSERT INTO transferredpoints (checkingpeer, checkedpeer, pointsamount)
            VALUES (NEW.checkingpeer, checked_peer_name, 1);
            
            RAISE NOTICE 'Созданы новые очки помощи для пары % -> %', 
                         NEW.checkingpeer, checked_peer_name;
        END IF;
    END IF;
    
    -- Триггерная функция всегда должна возвращать NEW для AFTER INSERT
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Создаем сам триггер
-- Триггер сработает ПОСЛЕ вставки новой записи в таблицу P2P
CREATE OR REPLACE TRIGGER trg_update_points
AFTER INSERT ON p2p
FOR EACH ROW  -- Для каждой новой строки
EXECUTE FUNCTION update_transferred_points();

-- Тестируем триггер:
-- 1. Добавляем новую P2P проверку (должен сработать триггер)
-- INSERT INTO p2p ("Check", checkingpeer, state, time)
-- VALUES (8, 'peer8', 'Start', '10:11:00');

-- 2. Проверяем, обновились ли очки помощи
-- SELECT * FROM transferredpoints WHERE checkingpeer = 'peer8';


-- 4) Триггер для проверки XP перед добавлением
-- Это как стражник, который проверяет, можно ли добавить XP

CREATE OR REPLACE FUNCTION check_xp_before_insert()
RETURNS TRIGGER AS $$
DECLARE
    max_xp_allowed INTEGER;    -- Максимально возможные XP за задание
    p2p_result check_status;   -- Результат P2P проверки
    verter_result check_status; -- Результат автотестов
BEGIN
    -- 1. Получаем максимальные XP за это задание
    SELECT tasks.maxxp INTO max_xp_allowed
    FROM checks
    JOIN tasks ON checks.task = tasks.title
    WHERE checks.id = NEW."Check";
    
    -- 2. Получаем результат P2P проверки
    SELECT state INTO p2p_result
    FROM p2p
    WHERE "Check" = NEW."Check"
        AND state IN ('Success', 'Failure')
    ORDER BY time DESC
    LIMIT 1;
    
    -- 3. Получаем результат автотестов (если есть)
    SELECT state INTO verter_result
    FROM verter
    WHERE "Check" = NEW."Check"
        AND state IN ('Success', 'Failure')
    ORDER BY time DESC
    LIMIT 1;
    
    -- Проверка 1: XP не должно превышать максимальные
    IF (NEW.xpamount > max_xp_allowed) THEN
        RAISE EXCEPTION 'Слишком много XP! Максимум для этого задания: %', max_xp_allowed;
    END IF;
    
    -- Проверка 2: P2P проверка должна быть успешной
    IF (p2p_result != 'Success') THEN
        RAISE EXCEPTION 'P2P проверка не была успешной! Результат: %', p2p_result;
    END IF;
    
    -- Проверка 3: Если были автотесты, они тоже должны быть успешными
    IF (verter_result IS NOT NULL AND verter_result != 'Success') THEN
        RAISE EXCEPTION 'Автотесты не пройдены! Результат: %', verter_result;
    END IF;
    
    -- Проверка 4: XP должно быть положительным числом
    IF (NEW.xpamount <= 0) THEN
        RAISE EXCEPTION 'XP должно быть положительным числом!';
    END IF;
    
    -- Если все проверки пройдены, разрешаем вставку
    RAISE NOTICE 'XP успешно добавлены!';
    RETURN NEW;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Если произошла ошибка, отменяем вставку
        RAISE NOTICE 'Вставка XP отменена: %', SQLERRM;
        RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Создаем триггер, который сработает ПЕРЕД вставкой в таблицу XP
CREATE OR REPLACE TRIGGER trg_check_xp
BEFORE INSERT ON xp
FOR EACH ROW
EXECUTE FUNCTION check_xp_before_insert();

-- Тестируем триггер:
-- 1. Пытаемся добавить корректные XP (должно сработать)
-- INSERT INTO xp ("Check", xpamount) VALUES (13, 100);

-- 2. Пытаемся добавить слишком много XP (должна быть ошибка)
-- INSERT INTO xp ("Check", xpamount) VALUES (16, 1150);

-- 3. Пытаемся добавить XP для неуспешной проверки (должна быть ошибка)
-- INSERT INTO xp ("Check", xpamount) VALUES (19, 300);


-- Функция для удаления всех тестовых данных (чтобы не засорять базу)
CREATE OR REPLACE PROCEDURE cleanup_test_data() AS $$
BEGIN
    -- Удаляем добавленные XP
    DELETE FROM xp WHERE id > (SELECT MAX(id) - 5 FROM xp);
    
    -- Удаляем добавленные проверки Verter
    DELETE FROM verter WHERE id > (SELECT MAX(id) - 5 FROM verter);
    
    -- Удаляем добавленные P2P проверки
    DELETE FROM p2p WHERE id > (SELECT MAX(id) - 5 FROM p2p);
    
    -- Удаляем добавленные Checks
    DELETE FROM checks WHERE id > (SELECT MAX(id) - 5 FROM checks);
    
    -- Восстанавливаем transferredpoints
    DELETE FROM transferredpoints WHERE id > (SELECT MAX(id) - 5 FROM transferredpoints);
    
    RAISE NOTICE 'Тестовые данные удалены!';
END;
$$ LANGUAGE plpgsql;

-- Удаляем триггеры и функции если нужно пересоздать
-- DROP TRIGGER IF EXISTS trg_update_points ON p2p;
-- DROP TRIGGER IF EXISTS trg_check_xp ON xp;
-- DROP FUNCTION IF EXISTS update_transferred_points();
-- DROP FUNCTION IF EXISTS check_xp_before_insert();
-- DROP PROCEDURE IF EXISTS add_peer_review(varchar, varchar, text, check_status, time);
-- DROP PROCEDURE IF EXISTS add_verter_review(varchar, text, check_status, time);
