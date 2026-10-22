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
-- консултации (директно, както съществуват в реалната база)
insert into public.consultations(teacher_id,day,shift,hour,subject,location) values
 ('00000000-0000-0000-0000-0000000000b1',1,1,7,'Математика','каб. 1'),
 ('00000000-0000-0000-0000-0000000000b1',1,2,1,'Математика','каб. 1'),
 ('00000000-0000-0000-0000-0000000000b2',2,2,3,'Български','каб. 2'),
 ('00000000-0000-0000-0000-0000000000b3',3,1,2,'ИТ','каб. 3'),
 ('00000000-0000-0000-0000-0000000000b2',3,1,2,'ИТ','каб. 4');
insert into public.consultation_classes(consultation_id,class_id)
 select c.id, k.id from public.consultations c join public.classes k on k.name in ('5А','5Б') where c.subject='Математика'
 union all select c.id, k.id from public.consultations c join public.classes k on k.name='9А' where c.subject='Български'
 union all select c.id, k.id from public.consultations c join public.classes k on k.name='8Б' where c.subject='ИТ';
