using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Gimano.Core.Data.Migrations
{
    /// <inheritdoc />
    public partial class AppealsOsmFlagsFeedbackSpam : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "appeal_evidence",
                table: "reviews",
                type: "character varying(300)",
                maxLength: 300,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "appeal_evidence",
                table: "photos",
                type: "character varying(300)",
                maxLength: 300,
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "suspected_spam",
                table: "feedback",
                type: "boolean",
                nullable: false,
                defaultValue: false);

            migrationBuilder.CreateTable(
                name: "content_appeals",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    refusal_id = table.Column<Guid>(type: "uuid", nullable: false),
                    user_id = table.Column<Guid>(type: "uuid", nullable: false),
                    kind = table.Column<string>(type: "character varying(8)", maxLength: 8, nullable: false),
                    place_id = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: false),
                    rating = table.Column<int>(type: "integer", nullable: true),
                    text = table.Column<string>(type: "character varying(2000)", maxLength: 2000, nullable: true),
                    reasons = table.Column<string>(type: "character varying(160)", maxLength: 160, nullable: true),
                    note = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: false),
                    evidence_keys = table.Column<string>(type: "character varying(300)", maxLength: 300, nullable: true),
                    status = table.Column<string>(type: "character varying(10)", maxLength: 10, nullable: false),
                    review_id = table.Column<Guid>(type: "uuid", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    decided_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    scrubbed_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_content_appeals", x => x.id);
                    table.ForeignKey(
                        name: "fk_content_appeals_users_user_id",
                        column: x => x.user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "osm_place_flags",
                columns: table => new
                {
                    place_id = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: false),
                    user_id = table.Column<Guid>(type: "uuid", nullable: false),
                    reason = table.Column<string>(type: "character varying(20)", maxLength: 20, nullable: false),
                    suggested_warnings = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_osm_place_flags", x => new { x.place_id, x.user_id });
                    table.ForeignKey(
                        name: "fk_osm_place_flags_users_user_id",
                        column: x => x.user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "ix_content_appeals_status",
                table: "content_appeals",
                column: "status");

            migrationBuilder.CreateIndex(
                name: "ix_content_appeals_user_id_refusal_id",
                table: "content_appeals",
                columns: new[] { "user_id", "refusal_id" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_osm_place_flags_user_id",
                table: "osm_place_flags",
                column: "user_id");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "content_appeals");

            migrationBuilder.DropTable(
                name: "osm_place_flags");

            migrationBuilder.DropColumn(
                name: "appeal_evidence",
                table: "reviews");

            migrationBuilder.DropColumn(
                name: "appeal_evidence",
                table: "photos");

            migrationBuilder.DropColumn(
                name: "suspected_spam",
                table: "feedback");
        }
    }
}
