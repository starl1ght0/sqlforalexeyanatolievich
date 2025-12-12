-- Это как создание таблицы в Excel - сначала говорим какие будут столбцы
-- Здесь храним всех наших пиров (учеников)
CREATE TABLE Peers
(
    Nickname varchar NOT NULL PRIMARY KEY, -- Псевдоним, он же уникальный ID
    Birthday date NOT NULL -- День рождения, чтобы знать когда поздравлять
);

-- Заполняем таблицу данными, как будто добавляем строки в Excel
-- Каждый peer - это ученик, который будет делать задания
INSERT INTO Peers (Nickname, Birthday)
VALUES ('peer1', '1990-01-01'),
       ('peer2', '1990-01-02'),
       ('peer3', '1990-01-03'),
       ('peer4', '1990-01-04'),
       ('peer5', '1990-01-05'),
       ('peer6', '1990-01-06'),
       ('peer7', '1990-01-07'),
       ('peer8', '1990-01-08'),
       ('peer9', '1990-01-09'),
       ('peer10', '1990-01-10');

-- Таблица с заданиями (проектами, которые нужно сделать)
-- Здесь целая цепочка заданий, как в игре - чтобы открыть новое, нужно сделать предыдущее
CREATE TABLE Tasks
(
    Title varchar PRIMARY KEY, -- Название задания (например "C2_SimpleBashUtils")
    ParentTask varchar, -- Родительское задание (что нужно сделать перед этим)
    MaxXP INTEGER NOT NULL, -- Максимальное количество XP за задание
    FOREIGN KEY (ParentTask) REFERENCES Tasks (Title) -- Связь с родительским заданием
);

-- Заполняем заданиями, это как древо заданий в Skyrim или другой RPG игре
INSERT INTO Tasks
VALUES ('C2_SimpleBashUtils', NULL, 250), -- Это первое задание, у него нет родителя
       ('C3_s21_string+', 'C2_SimpleBashUtils', 500), -- Чтобы сделать это, нужно сделать C2_SimpleBashUtils
       ('C4_s21_math', 'C2_SimpleBashUtils', 300),
       ('C5_s21_decimal', 'C4_s21_math', 350),
       -- ... и так далее, целая цепочка заданий
       ('SQL3_RetailAnalitycs v1.0', 'SQL2_Info21 v1.0', 600);

-- Создаем специальный тип данных - как список возможных значений
-- Статус проверки может быть только одним из трех
CREATE TYPE check_status AS ENUM ('Start', 'Success', 'Failure');

-- Таблица проверок (когда пир отправляет задание на проверку)
CREATE TABLE Checks
(
    ID BIGINT PRIMARY KEY NOT NULL, -- Уникальный номер проверки
    Peer varchar NOT NULL, -- Кто отправил на проверку
    Task varchar NOT NULL, -- Какое задание проверяем
    Date date NOT NULL, -- Когда отправил
    FOREIGN KEY (Peer) REFERENCES Peers (Nickname), -- Связь с таблицей пиров
    FOREIGN KEY (Task) REFERENCES Tasks (Title) -- Связь с таблицей заданий
);

-- Примеры проверок: peer1 отправил задание C2_SimpleBashUtils 1 марта
INSERT INTO Checks (id, peer, task, date)
VALUES (1, 'peer1', 'C2_SimpleBashUtils', '2023-03-01'),
       (2, 'peer1', 'C2_SimpleBashUtils', '2023-03-02'), -- Повторно отправил после провала
       -- ... и другие проверки
       (30, 'peer3', 'C8_3DViewer_v1.0', '2023-03-10');

-- Таблица P2P проверок (когда один пир проверяет работу другого)
-- Это как peer review в школе
CREATE TABLE P2P
(
    ID BIGINT PRIMARY KEY NOT NULL, -- Уникальный ID записи
    "Check" BIGINT NOT NULL, -- На какую проверку из Checks ссылаемся
    CheckingPeer varchar NOT NULL, -- Кто проверяет
    State check_status NOT NULL, -- Статус: начал проверку, принял или отклонил
    Time time NOT NULL, -- Время действия
    FOREIGN KEY ("Check") REFERENCES Checks (ID), -- Связь с проверкой
    FOREIGN KEY (CheckingPeer) REFERENCES Peers (Nickname) -- Связь с проверяющим пиром
);

-- Пример: проверка №1, peer2 проверяет, начал в 9:00, завершил неудачей в 10:00
INSERT INTO P2P (id, "Check", CheckingPeer, State, Time)
VALUES (1, 1, 'peer2', 'Start', '09:00:00'),
       (2, 1, 'peer2', 'Failure', '10:00:00'), -- Пир завалил проверку
       (3, 2, 'peer3', 'Start', '13:00:00'),
       (4, 2, 'peer3', 'Success', '14:00:00'), -- На этот раз прошел
       -- ... и так далее
       (58, 30, 'peer10', 'Success', '23:00:00');

-- Таблица автоматической проверки (Verter - как автоматический тест)
-- После успешной P2P проверки идет автоматическая проверка
CREATE TABLE Verter
(
    ID bigint PRIMARY KEY NOT NULL,
    "Check" bigint NOT NULL, -- Ссылка на проверку
    State check_status NOT NULL, -- Результат автотестов
    Time time NOT NULL, -- Когда произошло
    FOREIGN KEY ("Check") REFERENCES Checks (ID)
);

-- Пример: проверка №2 прошла автотесты успешно
INSERT INTO Verter (id, "Check", State, Time)
VALUES (1, 2, 'Start', '13:01:00'),
       (2, 2, 'Success', '13:02:00'), -- Автотесты пройдены!
       (3, 3, 'Start', '23:01:00'),
       (4, 3, 'Success', '23:02:00'),
       -- ... остальные записи
       (38, 30, 'Success', '23:02:00');

-- Таблица передаваемых очков (когда пир проверяет другого, он тратит время)
-- За каждую проверку проверяющий получает "очки помощи"
CREATE TABLE TransferredPoints
(
    ID bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY, -- Автоматический ID
    CheckingPeer varchar NOT NULL, -- Кто проверял
    CheckedPeer varchar NOT NULL, -- Кого проверял
    PointsAmount integer NOT NULL, -- Сколько очков передано
    FOREIGN KEY (CheckingPeer) REFERENCES Peers (Nickname),
    FOREIGN KEY (CheckedPeer) REFERENCES Peers (Nickname)
);

-- Автоматически заполняем на основе P2P проверок
-- Считаем сколько раз каждый пир проверял другого
INSERT INTO TransferredPoints (CheckingPeer, CheckedPeer, PointsAmount)
SELECT checkingpeer, Peer, COUNT(*) 
FROM P2P
JOIN Checks C ON C.ID = P2P."Check"
WHERE State != 'Start' -- Только завершенные проверки
GROUP BY 1,2;

-- Таблица друзей (кто с кем дружит)
CREATE TABLE Friends
(
    ID bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY, -- Автоматический ID
    Peer1 varchar NOT NULL, -- Первый друг
    Peer2 varchar NOT NULL, -- Второй друг
    FOREIGN KEY (Peer1) REFERENCES Peers (Nickname),
    FOREIGN KEY (Peer2) REFERENCES Peers (Nickname)
);

-- Автозаполнение: делаем всех пиров друзьями друг с другом
-- Это как в соцсети "добавить всех в друзья"
INSERT INTO Friends (Peer1, Peer2)
SELECT p.Nickname, p2.Nickname
FROM Peers p, Peers p2
WHERE p.Nickname < p2.Nickname; -- Чтобы не было дублей (A-B и B-A)

-- Таблица рекомендаций (кого посоветовать для проверки)
-- Если peer1 хорошо проверяет, его рекомендуют другим
CREATE TABLE Recommendations
(
    ID bigint PRIMARY KEY NOT NULL,
    Peer varchar NOT NULL, -- Кому рекомендуют
    RecommendedPeer varchar NOT NULL, -- Кого рекомендуют
    FOREIGN KEY (Peer) REFERENCES Peers (Nickname),
    FOREIGN KEY (RecommendedPeer) REFERENCES Peers (Nickname)
);

-- Пример: peer1 рекомендует peer2 и peer3 для проверок
INSERT INTO Recommendations (id, Peer, RecommendedPeer)
VALUES (1, 'peer1', 'peer2'),
       (2, 'peer1', 'peer3'),
       -- ... и другие рекомендации
       (10, 'peer9', 'peer6');

-- Таблица полученного опыта (сколько XP получил за задание)
-- Не всегда дают максимум, могут снять за ошибки
CREATE TABLE XP
(
    ID bigint PRIMARY KEY,
    "Check" bigint NOT NULL, -- За какую проверку
    XPAmount integer NOT NULL, -- Сколько XP получено
    FOREIGN KEY ("Check") REFERENCES Checks (ID)
);

-- Пример: за проверку №2 дали 240 XP из 250 возможных
INSERT INTO XP (id, "Check", XPAmount)
VALUES (1, 2, 240),
       (2, 3, 300),
       -- ... и другие начисления XP
       (22, 30, 750);

-- Таблица учета времени (когда пир заходил и выходил)
-- Как система контроля доступа в школе
CREATE TABLE TimeTracking
(
    ID bigint PRIMARY KEY NOT NULL,
    Peer varchar NOT NULL, -- Кто
    Date date NOT NULL, -- Когда (день)
    Time time NOT NULL, -- Во сколько
    State bigint NOT NULL CHECK (State IN (1, 2)), -- 1 = вошел, 2 = вышел
    FOREIGN KEY (Peer) REFERENCES Peers (Nickname)
);

-- Пример: peer1 зашел 2 марта в 8:00, вышел в 18:00
INSERT INTO TimeTracking (id, Peer, Date, Time, State)
VALUES (1, 'peer1', '2023-03-02', '08:00:00', 1),
       (2, 'peer1', '2023-03-02', '18:00:00', 2),
       -- ... другие записи о входе/выходе
       (14, 'peer7', '2023-05-02', '23:50:00', 2);

-- Процедура экспорта (выгрузить таблицу в CSV файл)
-- Это как экспорт из Excel в CSV
CREATE OR REPLACE PROCEDURE export_data(
    IN tablename varchar, -- Какую таблицу выгружаем
    IN path text, -- Куда сохраняем (путь к файлу)
    IN separator char -- Какой разделитель использовать (обычно запятая)
) AS $$
BEGIN
    -- Формируем команду COPY для экспорта
    -- format() подставляет переменные в строку
    EXECUTE format(
        'COPY %s TO ''%s'' DELIMITER ''%s'' CSV HEADER;',
        tablename, path, separator
    );
END;
$$ LANGUAGE plpgsql;

-- Процедура импорта (загрузить данные из CSV файла)
-- Это как импорт CSV в Excel
CREATE OR REPLACE PROCEDURE import_data(
    IN tablename varchar, -- В какую таблицу загружаем
    IN path text, -- Откуда берем файл
    IN separator char -- Какой разделитель в файле
) AS $$
BEGIN
    -- Формируем команду COPY для импорта
    EXECUTE format(
        'COPY %s FROM ''%s'' DELIMITER ''%s'' CSV HEADER;',
        tablename, path, separator
    );
END;
$$ LANGUAGE plpgsql;
