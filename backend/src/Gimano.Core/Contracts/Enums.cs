namespace Gimano.Core.Contracts;

// All enums are serialised as snake_case strings (see GimanoJson).

public enum Platform { Android, Ios }

public enum Vehicle { Car, Motorcycle, Bicycle, Walk }

public enum SavedPlaceKind { Home, Work, Favorite }

public enum ReportType { Traffic, Police, Accident, Hazard, Closure, BlockedLane, MapIssue, Weather, Animal }

public enum RouteLabel { Best, Alternative }

/// <summary>Why a route is offered next to the fastest one (docs/api.md, "Route options").</summary>
public enum RouteReason { Fastest, Shortest, LowerToll, NoTolls, FewerReports, OtherMainRoad }

/// <summary>Why an alternative is not worth offering: almost the same road as a shown route, far slower, or clearly worse.</summary>
public enum RouteHidden { SameRoad, Slower, Worse }

public enum PlaceCategory
{
    Fuel, EvCharging, RestArea, TollBooth, Parking, Restaurant, Cafe, FastFood, Mall, Supermarket,
    Convenience, Mosque, Surau, Temple, Church, Hospital, Clinic, Pharmacy, Police, School, University,
    Hotel, Atm, Bank, CarRepair, CarWash, Tourism, TransitStation, Airport, Government, Other,
    /// <summary>A city, town, suburb, village, neighbourhood or administrative area (searchable by name).</summary>
    Area,
    /// <summary>Public toilets (amenity=toilets).</summary>
    Toilets,
    /// <summary>Search-only result kinds: a named street, a house address, a postcode area, a coordinate / Plus Code point.</summary>
    Street, Address, Postcode, Point
}

public enum ManeuverType
{
    Depart, Arrive, Straight, SlightLeft, Left, SharpLeft, SlightRight, Right, SharpRight, UturnLeft, UturnRight,
    RoundaboutEnter, RoundaboutExit, Merge, RampLeft, RampRight, ExitLeft, ExitRight, KeepLeft, KeepRight, Ferry
}

public enum FavoriteIcon { Home, Work, Kampung, Mertua, Star, Heart, School, Surau, Food, Gym, Shop, Hospital }

public enum TollSystem { Open, ClosedEntry, ClosedExit }

public enum FeedbackCategory { Bug, Idea, MapData, Route, Search, Other }

public enum FeedbackScreen { Home, Search, Place, RoutePreview, Navigation, Report, Settings, Other }

public enum FeedbackStatus { Received, Triaged, Planned, Done, WontFix }

/// <summary>Back-office triage severity: S1 = crash or data loss for many, S4 = cosmetic.</summary>
public enum Severity { S1, S2, S3, S4 }

/// <summary>A reply to a feedback reporter: drafted (possibly by an agent), then sent or discarded by a maintainer.</summary>
public enum ReplyStatus { Draft, Sent, Discarded }

public enum AgentRunStatus { Running, WaitingForReview, Done, Cancelled, Failed }

public enum PlaceSource { Osm, Community }

/// <summary>Community place lifecycle. Only <c>pending</c>/<c>published</c> appear in PlaceSummary.status.</summary>
/// <summary>Rejected: the AI check didn't accept it (owner only; may be edited or appealed once).</summary>
public enum PlaceStatus { Pending, Published, Hidden, Closed, Expired, Rejected }

public enum ReviewStatus { Published, Hidden }

public enum ReviewSort { Recent, Helpful }

public enum FlagReason { Spam, Offensive, OffTopic, ConflictOfInterest, Other, SensitiveLocation }

public enum PhotoStatus { Processing, Published, Rejected }

public enum InboxKind { PlacePublished, PlaceRejected, ReportThanked, ReviewHelpful, EditAccepted, FeedbackStatus, Announcement, PlaceExpired,
    IssueConfirmed, IssueRefuted, IssueResolved, PlaceHeld, PlaceNotAccepted, PlaceLive,
    ContentPublished, ContentHeld, ContentRejected }

/// <summary>Road and place complaints (docs/complaints.md, docs/api.md "Issues").</summary>
public enum IssueKind
{
    RoadClosedTemp, RoadNotExist, OnewayWrongClosedDir, OnewayWrongOpenDir, TurnNotAllowed, OddRoute, NewRoad,
    PlaceClosedPerm, PlaceClosedTemp, PlaceHoursWrong, PlaceEntranceWrong, PlaceInfoWrong, PlaceDuplicate,
}

/// <summary>reported (feedback-only kinds) · suspected · confirmed · refuted · expired · resolved.</summary>
public enum IssueState { Reported, Suspected, Confirmed, Refuted, Expired, Resolved }

/// <summary>Which way along the segment (relative to the OSM digitised direction) the issue applies.</summary>
public enum IssueDirection { Both, Forward, Backward }

public enum IssueSource { Report, Deviation, PlaceEdit }

/// <summary>Vote on an issue: it still holds · it's cleared / was never true · unsure (weight 0).</summary>
public enum IssueAnswer { Still, Cleared, Unsure }

/// <summary>Contributor trust tier (docs/identity-and-reputation.md).</summary>
public enum Tier { Baharu, Perak, Emas }
