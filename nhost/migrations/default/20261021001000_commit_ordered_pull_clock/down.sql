-- Forward-compatible safety rollback: keep the allocator and triggers. Old
-- clients also use timestamp/id cursors and need the same ordering guarantee.
-- Removing this clock after clients advanced their cursors can lose rows.
-- A future explicit replacement must retain the greatest allocated timestamp.
SELECT 1;
