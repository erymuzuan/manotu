using System;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace Gimano.Core.Data.Migrations
{
    /// <inheritdoc />
    public partial class ContentSafety : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "appeal_note",
                table: "reviews",
                type: "character varying(200)",
                maxLength: 200,
                nullable: true);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "appealed_at",
                table: "reviews",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "moderated_at",
                table: "reviews",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "moderation_reasons",
                table: "reviews",
                type: "character varying(160)",
                maxLength: 160,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "moderation_state",
                table: "reviews",
                type: "character varying(10)",
                maxLength: 10,
                nullable: false,
                defaultValue: "None");

            migrationBuilder.AddColumn<string>(
                name: "appeal_note",
                table: "photos",
                type: "character varying(200)",
                maxLength: 200,
                nullable: true);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "appealed_at",
                table: "photos",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "moderated_at",
                table: "photos",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "moderation_reasons",
                table: "photos",
                type: "character varying(160)",
                maxLength: 160,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "moderation_state",
                table: "photos",
                type: "character varying(10)",
                maxLength: 10,
                nullable: false,
                defaultValue: "None");

            migrationBuilder.AddColumn<bool>(
                name: "can_appeal",
                table: "inbox_items",
                type: "boolean",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "place_id",
                table: "inbox_items",
                type: "character varying(40)",
                maxLength: 40,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "reasons",
                table: "inbox_items",
                type: "character varying(160)",
                maxLength: 160,
                nullable: true);

            migrationBuilder.AlterColumn<string>(
                name: "screening_reasons",
                table: "community_places",
                type: "character varying(160)",
                maxLength: 160,
                nullable: true,
                oldClrType: typeof(string),
                oldType: "character varying(80)",
                oldMaxLength: 80,
                oldNullable: true);

            migrationBuilder.AddColumn<string>(
                name: "owner_warnings",
                table: "community_places",
                type: "character varying(40)",
                maxLength: 40,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "warnings",
                table: "community_places",
                type: "character varying(40)",
                maxLength: 40,
                nullable: true);

            migrationBuilder.CreateTable(
                name: "content_rejections",
                columns: table => new
                {
                    id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    user_id = table.Column<Guid>(type: "uuid", nullable: false),
                    at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_content_rejections", x => x.id);
                    table.ForeignKey(
                        name: "fk_content_rejections_users_user_id",
                        column: x => x.user_id,
                        principalTable: "users",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateTable(
                name: "watched_brands",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    name = table.Column<string>(type: "character varying(80)", maxLength: 80, nullable: false),
                    aliases = table.Column<string>(type: "character varying(400)", maxLength: 400, nullable: true),
                    group = table.Column<string>(type: "character varying(24)", maxLength: 24, nullable: false),
                    place_mode = table.Column<string>(type: "character varying(8)", maxLength: 8, nullable: false),
                    text_mode = table.Column<string>(type: "character varying(12)", maxLength: 12, nullable: false),
                    enabled = table.Column<bool>(type: "boolean", nullable: false),
                    updated_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    updated_by = table.Column<string>(type: "character varying(120)", maxLength: 120, nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_watched_brands", x => x.id);
                });

            migrationBuilder.CreateIndex(
                name: "ix_content_rejections_user_id_at",
                table: "content_rejections",
                columns: new[] { "user_id", "at" });

            migrationBuilder.CreateIndex(
                name: "ix_watched_brands_name",
                table: "watched_brands",
                column: "name",
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "content_rejections");

            migrationBuilder.DropTable(
                name: "watched_brands");

            migrationBuilder.DropColumn(
                name: "appeal_note",
                table: "reviews");

            migrationBuilder.DropColumn(
                name: "appealed_at",
                table: "reviews");

            migrationBuilder.DropColumn(
                name: "moderated_at",
                table: "reviews");

            migrationBuilder.DropColumn(
                name: "moderation_reasons",
                table: "reviews");

            migrationBuilder.DropColumn(
                name: "moderation_state",
                table: "reviews");

            migrationBuilder.DropColumn(
                name: "appeal_note",
                table: "photos");

            migrationBuilder.DropColumn(
                name: "appealed_at",
                table: "photos");

            migrationBuilder.DropColumn(
                name: "moderated_at",
                table: "photos");

            migrationBuilder.DropColumn(
                name: "moderation_reasons",
                table: "photos");

            migrationBuilder.DropColumn(
                name: "moderation_state",
                table: "photos");

            migrationBuilder.DropColumn(
                name: "can_appeal",
                table: "inbox_items");

            migrationBuilder.DropColumn(
                name: "place_id",
                table: "inbox_items");

            migrationBuilder.DropColumn(
                name: "reasons",
                table: "inbox_items");

            migrationBuilder.DropColumn(
                name: "owner_warnings",
                table: "community_places");

            migrationBuilder.DropColumn(
                name: "warnings",
                table: "community_places");

            migrationBuilder.AlterColumn<string>(
                name: "screening_reasons",
                table: "community_places",
                type: "character varying(80)",
                maxLength: 80,
                nullable: true,
                oldClrType: typeof(string),
                oldType: "character varying(160)",
                oldMaxLength: 160,
                oldNullable: true);
        }
    }
}
