-- Synthetic fixture for the atomic RPC boundary; not a full Nhost deployment.

CREATE SCHEMA auth;

CREATE TABLE auth.users(id uuid PRIMARY KEY, disabled boolean DEFAULT false);

CREATE TABLE public.accounts(id uuid PRIMARY KEY, frozen boolean DEFAULT false);

CREATE TABLE public.super_admins(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_uid uuid UNIQUE,disabled boolean DEFAULT false);

CREATE TABLE public.account_users(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),account_id uuid,user_uid uuid,disabled boolean DEFAULT false,role text, UNIQUE(account_id,user_uid));

CREATE TABLE public.account_feature_permissions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),account_id uuid,user_uid uuid,allowed_features text[] DEFAULT ARRAY[]::text[],allow_all boolean DEFAULT false,can_create boolean DEFAULT false,can_update boolean DEFAULT false,can_delete boolean DEFAULT false,UNIQUE(account_id,user_uid));

CREATE TABLE public.client_mutations(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),account_id uuid NOT NULL,client_mutation_id text NOT NULL,operation_type text NOT NULL,actor_user_id uuid,payload_hash text,result_json jsonb,created_at timestamptz DEFAULT now(),completed_at timestamptz,correlation_id uuid,UNIQUE(account_id,client_mutation_id));

CREATE TABLE public.sync_events(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),account_id uuid NOT NULL,domain text NOT NULL,entity_table text NOT NULL,entity_id uuid,operation_type text NOT NULL,created_at timestamptz DEFAULT now(),actor_user_id uuid,client_mutation_id text,correlation_id uuid,UNIQUE(account_id,client_mutation_id));

CREATE TABLE public."item_types"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "name" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."items"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "type_id" uuid,
  "name" text,
  "price" numeric,
  "stock" integer NOT NULL DEFAULT 0,
  "created_at" timestamp with time zone DEFAULT now(),
  "is_deleted" boolean,
  "deleted_at" timestamp with time zone,
  "client_mutation_id" text,
  "deleted_by_user_id" uuid,
  "deletion_client_mutation_id" text,
  "server_version" integer,
  "updated_by_user_id" uuid,
  "price_minor" bigint,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."drugs"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "name" text,
  "notes" text,
  "created_at" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."medical_services"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "name" text,
  "cost" text,
  "cost_minor" bigint,
  "service_type" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."consumption_types"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "type" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."employees"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "name" text,
  "identity_number" text,
  "phone_number" text,
  "job_title" text,
  "address" text,
  "marital_status" text,
  "basic_salary" text,
  "basic_salary_minor" bigint,
  "final_salary" text,
  "final_salary_minor" bigint,
  "is_doctor" text,
  "user_uid" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."doctors"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "employee_id" text,
  "user_uid" text,
  "name" text,
  "specialization" text,
  "phone_number" text,
  "start_time" text,
  "end_time" text,
  "print_counter" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."service_doctor_share"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "service_id" text,
  "doctor_id" text,
  "share_percentage" text,
  "tower_share_percentage" text,
  "is_hidden" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."patients"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "name" text,
  "age" smallint,
  "diagnosis" text,
  "phone_number" text,
  "register_date" date,
  "paid_amount" numeric,
  "remaining" numeric,
  "health_status" text,
  "notes" text,
  "preferences" text,
  "doctor_id" uuid,
  "doctor_name" text,
  "doctor_specialization" text,
  "service_type" text,
  "service_id" uuid,
  "service_name" text,
  "service_cost" numeric,
  "doctor_share" numeric,
  "doctor_input" numeric,
  "tower_share" numeric,
  "department_share" numeric,
  "doctor_review_pending" boolean,
  "doctor_reviewed_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now(),
  "is_deleted" boolean,
  "deleted_at" timestamp with time zone,
  "collateral" text,
  "client_mutation_id" text,
  "deleted_by_user_id" uuid,
  "deletion_client_mutation_id" text,
  "server_version" integer,
  "updated_by_user_id" uuid,
  "paid_amount_minor" bigint,
  "remaining_minor" bigint,
  "service_cost_minor" bigint,
  "doctor_share_minor" bigint,
  "doctor_input_minor" bigint,
  "tower_share_minor" bigint,
  "department_share_minor" bigint,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."patient_services"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "patient_id" text,
  "service_id" text,
  "service_name" text,
  "service_cost" text,
  "service_cost_minor" bigint,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."returns"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "date" text,
  "patient_name" text,
  "phone_number" text,
  "diagnosis" text,
  "remaining" text,
  "remaining_minor" bigint,
  "age" text,
  "doctor" text,
  "notes" text,
  "is_attended" text,
  "attended_at" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."appointments"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "patient_id" text,
  "doctor_id" text,
  "appointment_time" text,
  "status" text,
  "notes" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."prescriptions"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "patient_id" text,
  "doctor_id" text,
  "record_date" text,
  "created_at" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."prescription_items"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "prescription_id" text,
  "drug_id" text,
  "days" text,
  "times_per_day" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."consumptions"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "quantity" integer,
  "date" timestamp with time zone,
  "amount" double precision,
  "note" text,
  "created_at" timestamp with time zone DEFAULT now(),
  "patient_id" uuid,
  "item_id" uuid,
  "is_deleted" boolean,
  "deleted_at" timestamp with time zone,
  "client_mutation_id" text,
  "deleted_by_user_id" uuid,
  "deletion_client_mutation_id" text,
  "server_version" integer,
  "updated_by_user_id" uuid,
  "unit_price_snapshot" numeric(20,4),
  "unit_price_minor" bigint,
  "amount_minor" bigint,
  "reversed_at" timestamptz,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."purchases"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "date" timestamp with time zone,
  "item_id" uuid,
  "quantity" integer,
  "total" double precision,
  "created_at" timestamp with time zone DEFAULT now(),
  "is_deleted" boolean,
  "deleted_at" timestamp with time zone,
  "client_mutation_id" text,
  "deleted_by_user_id" uuid,
  "deletion_client_mutation_id" text,
  "server_version" integer,
  "updated_by_user_id" uuid,
  "unit_price_snapshot" numeric(20,4),
  "unit_price_minor" bigint,
  "amount_minor" bigint,
  "reversed_at" timestamptz,
  "item_name_snapshot" text,
  "item_type_name_snapshot" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."alert_settings"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "item_id" text,
  "item_uuid" text,
  "threshold" text,
  "is_enabled" text,
  "last_triggered" text,
  "created_at" text,
  "notify_time" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."employees_loans"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "employee_id" text,
  "loan_date_time" text,
  "final_salary" text,
  "final_salary_minor" bigint,
  "ratio_sum" text,
  "ratio_sum_minor" bigint,
  "loan_amount" text,
  "loan_amount_minor" bigint,
  "leftover" text,
  "leftover_minor" bigint,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."employees_salaries"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "employee_id" text,
  "year" text,
  "month" text,
  "final_salary" text,
  "final_salary_minor" bigint,
  "ratio_sum" text,
  "ratio_sum_minor" bigint,
  "total_loans" text,
  "total_loans_minor" bigint,
  "total_discounts" text,
  "total_discounts_minor" bigint,
  "net_pay" text,
  "net_pay_minor" bigint,
  "is_paid" text,
  "payment_date" text,
  "period_start" text,
  "period_end" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."employees_discounts"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "employee_id" text,
  "discount_date_time" text,
  "amount" text,
  "amount_minor" bigint,
  "notes" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."complaints"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "subject" text,
  "message" text,
  "status" text,
  "reply_message" text,
  "replied_at" text,
  "replied_by" text,
  "handled_by" text,
  "handled_at" text,
  "created_at" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

CREATE TABLE public."financial_logs"(
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "account_id" uuid NOT NULL REFERENCES public.accounts(id),
  "device_id" text NOT NULL,
  "local_id" bigint NOT NULL,
  "updated_at" timestamptz DEFAULT now(),
  "transaction_type" text,
  "operation" text,
  "amount" text,
  "amount_minor" bigint,
  "employee_id" text,
  "patient_id" text,
  "description" text,
  "modification_details" text,
  "timestamp" text,
  UNIQUE(account_id,device_id,local_id), UNIQUE(account_id,id)
);

ALTER TABLE public.items ADD FOREIGN KEY(account_id,type_id) REFERENCES public.item_types(account_id,id);

ALTER TABLE public.purchases ADD FOREIGN KEY(account_id,item_id) REFERENCES public.items(account_id,id);

ALTER TABLE public.consumptions ADD FOREIGN KEY(account_id,item_id) REFERENCES public.items(account_id,id);
