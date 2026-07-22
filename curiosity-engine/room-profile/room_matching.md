Goal: analyze room data and classify rooms

How: See @room_types.json with hospital room categories - name and profile are main facts.
Next process all @room_metadata.csv entries, use: room_name, floor_name, building_name, campus_name, department_name to make a decision to which room type room should be classified.
Finally create a set of sql updates to:  
update room by id to set it: entity_room_type_id, entity_room_type_name, room_type_profile, company_id.
Room type profile doesn't exists yet in room_metadata table - assume it exits with name room_type_profile.