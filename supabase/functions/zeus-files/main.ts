import { createGateway } from "./index.ts";
Deno.serve(createGateway(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!));
