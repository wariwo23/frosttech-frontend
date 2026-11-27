import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const INVITE_REDIRECT =
  "https://wariwo23.github.io/frosttech-frontend/employee-accept-invitation.html";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://wariwo23.github.io",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply(405, { error: "Method not allowed" });

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return reply(500, { error: "Server configuration is incomplete" });
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return reply(401, { error: "Please sign in as Super Administrator" });
  }

  const token = authorization.substring(7);
  const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const { data: userData, error: userError } = await callerClient.auth.getUser();
    if (userError || !userData.user) {
      return reply(401, { error: "Invalid administrator session" });
    }
    const actorUserId = userData.user.id;

    const { data: role, error: roleError } =
      await callerClient.rpc("admin_get_my_role");
    if (roleError || role !== "super_admin") {
      return reply(403, { error: "Super Administrator access required" });
    }

    const body = await req.json();
    const employeeId = body.employee_id;
    if (
      typeof employeeId !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(employeeId)
    ) {
      return reply(400, { error: "A valid employee ID is required" });
    }

    const { data: employee, error: employeeError } = await adminClient
      .from("frosttech_employees")
      .select("id, full_name, email, department, employment_status, auth_user_id")
      .eq("id", employeeId)
      .single();

    if (employeeError || !employee) {
      return reply(404, { error: "Employee record not found" });
    }

    // A completed link is a safe retry: validate it in the database and never send a second invitation.
    if (
      ["invited", "active"].includes(employee.employment_status) &&
      employee.auth_user_id
    ) {
      const { data: alreadyLinked, error: linkedError } =
        await adminClient.rpc("admin_complete_employee_invitation", {
          p_employee_id: employeeId,
          p_auth_user_id: employee.auth_user_id,
          p_actor_user_id: actorUserId,
        });

      if (linkedError || alreadyLinked !== true) {
        console.error("Existing employee link validation failed:", linkedError);
        return reply(409, {
          error: "The existing employee link needs Super Administrator review. No invitation email was sent.",
          employee_id: employeeId,
        });
      }

      return reply(200, {
        success: true,
        already_linked: true,
        message: "This employee invitation is already linked and verified. No duplicate email was sent.",
        employee_id: employeeId,
        email: employee.email,
      });
    }

    if (employee.employment_status !== "planned" || employee.auth_user_id) {
      return reply(409, {
        error: "This employee is not eligible for invitation or recovery.",
      });
    }

    // Recover an auth account created by a previous invitation attempt.
    // The lookup requires the unique employee ID written into invitation user metadata.
    const { data: recoveredUserId, error: recoveryLookupError } =
      await adminClient.rpc("admin_find_employee_invitation_user", {
        p_employee_id: employeeId,
      });

    if (recoveryLookupError) {
      console.error("Employee invitation recovery lookup failed:", recoveryLookupError);
      return reply(500, {
        error: "The invitation recovery check failed. No new email was sent.",
      });
    }

    let invitedUserId: string;
    let userForMetadata: Record<string, unknown>;
    let invitationWasSentNow = false;

    if (recoveredUserId) {
      invitedUserId = recoveredUserId as string;
      const { data: existing, error: existingError } =
        await adminClient.auth.admin.getUserById(invitedUserId);

      if (existingError || !existing.user) {
        return reply(500, {
          error: "A previous invitation account was found but could not be loaded. No new email was sent.",
          invitation_sent: true,
          employee_id: employeeId,
        });
      }
      userForMetadata = existing.user as unknown as Record<string, unknown>;
    } else {
      const { data: invitation, error: inviteError } =
        await adminClient.auth.admin.inviteUserByEmail(employee.email, {
          redirectTo: INVITE_REDIRECT,
          data: {
            full_name: employee.full_name,
            account_type: "employee",
            frosttech_employee_id: employeeId,
          },
        });

      if (inviteError || !invitation.user) {
        return reply(400, {
          error: inviteError?.message ?? "Invitation could not be sent",
        });
      }

      invitedUserId = invitation.user.id;
      userForMetadata = invitation.user as unknown as Record<string, unknown>;
      invitationWasSentNow = true;
    }

    const oldAppMetadata =
      (userForMetadata.app_metadata as Record<string, unknown> | undefined) ?? {};

    const { error: metadataError } =
      await adminClient.auth.admin.updateUserById(invitedUserId, {
        app_metadata: {
          ...oldAppMetadata,
          frosttech_account_type: "employee",
          frosttech_employee_id: employeeId,
        },
      });

    if (metadataError) {
      console.error("Employee metadata update failed:", metadataError);
      return reply(500, {
        error: "The invitation account exists, but its secure employee marker could not be saved. Retry recovery; do not create another employee record.",
        invitation_sent: invitationWasSentNow,
        recovery_pending: true,
        employee_id: employeeId,
      });
    }

    const { data: completed, error: completionError } =
      await adminClient.rpc("admin_complete_employee_invitation", {
        p_employee_id: employeeId,
        p_auth_user_id: invitedUserId,
        p_actor_user_id: actorUserId,
      });

    if (completionError || completed !== true) {
      console.error("Employee invitation completion failed:", completionError);
      return reply(500, {
        error: "The invitation account exists, but employee database linking needs recovery. Retry this same employee record.",
        invitation_sent: invitationWasSentNow,
        recovery_pending: true,
        employee_id: employeeId,
      });
    }

    return reply(200, {
      success: true,
      recovered: !invitationWasSentNow,
      message: invitationWasSentNow
        ? "Employee invitation sent and linked successfully."
        : "Previous employee invitation recovered and linked successfully. No duplicate email was sent.",
      employee_id: employeeId,
      email: employee.email,
      employment_status: "invited",
    });
  } catch (error) {
    console.error("Employee invitation error:", error);
    return reply(500, {
      error: "An unexpected error occurred while processing the employee invitation.",
    });
  }
});
