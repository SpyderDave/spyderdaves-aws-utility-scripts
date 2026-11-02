import boto3
import json

def get_full_hierarchy():
    client = boto3.client('organizations')
    
    # Get Root(s)
    roots = client.list_roots()['Roots']
    hierarchy = []
    
    for root in roots:
        root_id = root['Id']
        root_name = root['Name']
        node = {
            'id': root_id,
            'name': f"Root: {root_name}",
            'type': 'ROOT',
            'children': get_children(client, root_id)
        }
        hierarchy.append(node)
    return hierarchy

def get_children(client, parent_id):
    children_nodes = []
    
    # Get OUs
    ous = []
    paginator = client.get_paginator('list_organizational_units_for_parent')
    for page in paginator.paginate(ParentId=parent_id):
        ous.extend(page['OrganizationalUnits'])
        
    for ou in ous:
        ou_id = ou['Id']
        ou_name = ou['Name']
        children_nodes.append({
            'id': ou_id,
            'name': f"OU: {ou_name}",
            'type': 'OU',
            'children': get_children(client, ou_id)
        })
        
    # Get Accounts
    accounts = []
    acc_paginator = client.get_paginator('list_accounts_for_parent')
    for page in acc_paginator.paginate(ParentId=parent_id):
        accounts.extend(page['Accounts'])
        
    for acc in accounts:
        if acc['Status'] == 'ACTIVE':
            children_nodes.append({
                'id': acc['Id'],
                'name': f"Account: {acc['Name']} ({acc['Id']})",
                'type': 'ACCOUNT',
                'children': []
            })
            
    return children_nodes

def generate_drawio_xml(nodes, parent_xml="", x=100, y=100, y_offset=80):
    xml_elements = ""
    connections = ""
    current_x = x
    
    for i, node in enumerate(nodes):
        node_id = node['id']
        node_label = node['name'].replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        
        # Color coding boxes based on type
        fill_color = "#dae8fc" if node['type'] == 'ROOT' else ("#ffe6cc" if node['type'] == 'OU' else "#d5e8d4")
        
        xml_elements += f'''
        <mxCell id="{node_id}" value="{node_label}" style="rounded=1;whiteSpace=wrap;html=1;fillColor={fill_color};strokeColor=#6c8ebf;" vertex="1" parent="1">
            <mxGeometry x="{current_x}" y="{y}" width="180" height="50" as="geometry"/>
        </mxCell>'''
        
        if parent_xml:
            connections += f'''
            <mxCell id="conn_{parent_xml}_{node_id}" value="" style="endArrow=classic;html=1;entryX=0.5;entryY=0;exitX=0.5;exitY=1;" edge="1" parent="1" source="{parent_xml}" target="{node_id}">
                <mxGeometry relative="1" as="geometry"/>
            </mxCell>'''
            
        if node['children']:
            child_xml, child_conn, _ = generate_drawio_xml(node['children'], node_id, current_x, y + y_offset, y_offset)
            xml_elements += child_xml
            connections += child_conn
            
        current_x += 200
        
    return xml_elements, connections, current_x

if __name__ == "__main__":
    print("Fetching AWS Organizations hierarchy...")
    data = get_full_hierarchy()
    
    elements, conns, _ = generate_drawio_xml(data)
    
    drawio_file_content = f'''<?xml5 version="1.0" encoding="UTF-8"?>
<mxfile host="app.diagrams.net">
  <diagram name="Organization Structure">
    <mxGraphModel dx="1000" dy="1000" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="827" pageHeight="1169" math="0" shadow="0">
      <root>
        <mxCell id="0"/>
        <mxCell id="1" parent="0"/>
        {elements}
        {conns}
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>'''
    
    output_filename = "aws_org_structure.drawio"
    with open(output_filename, "w", encoding="utf-8") as f:
        f.write(drawio_file_content)
        
    print(f"Successfully generated {output_filename}. Download this file from CloudShell to open it in draw.io.")
