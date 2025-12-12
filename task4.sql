-- 1. Удалить все таблицы с "temp" в названии
CALL delete_tables_by_name('temp');

-- 2. Посчитать сколько у нас функций
DO $$
DECLARE count_result integer;
BEGIN
    CALL count_functions_with_params(count_result);
    RAISE NOTICE 'Функций с параметрами: %', count_result;
END $$;

-- 3. Найти где используется слово "check"
BEGIN;
CALL search_in_code('check', 'results');
FETCH ALL FROM results;
END;

-- 4. Посмотреть что у нас в базе
CALL show_database_objects();
CALL show_database_objects('table');  -- Только таблицы
