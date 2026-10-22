-- Данни като в реална инсталация преди миграцията
insert into auth.users(id,email,raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000000a1','admin@paisii.info','{"name":"Админ Админов"}'),
 ('00000000-0000-0000-0000-0000000000b1','t1@paisii.info','{"name":"Учител Първи"}'),
 ('00000000-0000-0000-0000-0000000000b2','t2@paisii.info','{"name":"Учител Втори"}'),
 ('00000000-0000-0000-0000-0000000000b3','t3@paisii.info','{"name":"Учител Трети"}');
set session_replication_role = replica;
update public.teachers set role='admin' where id='00000000-0000-0000-0000-0000000000a1';
set session_replication_role = origin;
insert into public.classes(name) select n||l from unnest(array[5,6,7,8,9,10,11,12]) n, unnest(array['А','Б','В']) l;
insert into public.group_subjects(subject) values ('ИТ'),('Информатика');
update public.group_subjects set enabled=true;
