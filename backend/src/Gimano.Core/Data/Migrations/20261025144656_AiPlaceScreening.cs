using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Gimano.Core.Data.Migrations
{
    /// <inheritdoc />
    public partial class AiPlaceScreening : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "appeal_note",
                table: "community_places",
                type: "character varying(200)",
                maxLength: 200,
                nullable: true);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "appealed_at",
                table: "community_places",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "listed",
                table: "community_places",
                type: "boolean",
                nullable: false,
                defaultValue: false);

            migrationBuilder.AddColumn<string>(
                name: "said_different_from",
                table: "community_places",
                type: "character varying(40)",
                maxLength: 40,
                nullable: true);

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "screened_at",
                table: "community_places",
                type: "timestamp with time zone",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "screening_confidence",
                table: "community_places",
                type: "character varying(8)",
                maxLength: 8,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "screening_reasons",
                table: "community_places",
                type: "character varying(80)",
                maxLength: 80,
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "screening_state",
                table: "community_places",
                type: "character varying(10)",
                maxLength: 10,
                nullable: false,
                defaultValue: "None");

            migrationBuilder.CreateTable(
                name: "ai_usage_weeks",
                columns: table => new
                {
                    week_start = table.Column<DateOnly>(type: "date", nullable: false),
                    calls = table.Column<int>(type: "integer", nullable: false),
                    input_tokens = table.Column<long>(type: "bigint", nullable: false),
                    output_tokens = table.Column<long>(type: "bigint", nullable: false),
                    cost_usd = table.Column<decimal>(type: "numeric(12,6)", precision: 12, scale: 6, nullable: false),
                    updated_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_ai_usage_weeks", x => x.week_start);
                });

            migrationBuilder.CreateIndex(
                name: "ix_community_places_screening_state",
                table: "community_places",
                column: "screening_state",
                filter: "screening_state = 'Checking'");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "ai_usage_weeks");

            migrationBuilder.DropIndex(
                name: "ix_community_places_screening_state",
                table: "community_places");

            migrationBuilder.DropColumn(
                name: "appeal_note",
                table: "community_places");

            migrationBuilder.DropColumn(
                name: "appealed_at",
                table: "community_places");

            migrationBuilder.DropColumn(
                name: "listed",
                table: "community_places");

            migrationBuilder.DropColumn(
                name: "said_different_from",
                table: "community_places");

            migrationBuilder.DropColumn(
                name: "screened_at",
                table: "community_places");

            migrationBuilder.DropColumn(
                name: "screening_confidence",
                table: "community_places");

            migrationBuilder.DropColumn(
                name: "screening_reasons",
                table: "community_places");

            migrationBuilder.DropColumn(
                name: "screening_state",
                table: "community_places");
        }
    }
}
